/**
 * 朗读队列（**纯逻辑**，单测覆盖）
 *
 * 职责：
 *   1. 把文本切成 TTS 能吃的"段" —— 单次 speak 上限 10,000 字符（官方文档）；
 *   2. 维护播放游标与状态（idle / speaking / paused / stopped）；
 *   3. 段内跳转/续读定位（seekTo：按章内字符偏移切当前段）。
 *
 * 为什么单独一层：TTS 的 IO（createEngine / speak）依赖 @kit.CoreSpeechKit，
 * 切段和游标推进是纯逻辑 —— CI 无模拟器也要可测（v1-design §9）。
 *
 * **段的语义**（2026-10-18 修订为章级，原页级 500 字方案已废弃）：
 *   段 = 朗读的**最小合成单元**。旧方案按物理页切 500 字段，实测三大听感问题
 *   （党哥 2026-10-18 实听反馈，findings §16.9）：
 *     ① 句号前后停顿莫名 —— 段与段各自独立 speak，段界 = 引擎停顿 + 接缝延迟叠加；
 *     ② 无标点处莫名连读 —— 500 字内无句界只能硬切，一句话拆两段各自合成；
 *     ③ 翻页"咯噔"中断 —— 页末重载文本重新 speak。
 *   三段问题同一个根因：**合成单元太小、接缝太多**。
 *   新方案：默认按**整章**切段（SPEAK_CHAPTER_TARGET=8000，官方上限的 4/5），
 *   绝大多数章节 = 一段读完，所有停顿交给引擎统一处理，接缝归零。
 *   翻页只是视觉跟随（音频流不断，见 Reader.onSpeakTick）；暂停续读用
 *   seekTo 在段内按句界回退定位（CoreSpeechKit 无段内断点，见 resume 注释）。
 *
 * 切段规则（优先级从高到低）：
 *   1. 超目标长：有句界 → 最后句界后回退切；无句界 → 硬切（病态长句兜底）；
 *   2. 句界（。！？；… 与换行）且已累积 ≥ 下限 → 收段；
 *   3. 不足下限的碎句继续累积（防"句句切"的碎片化）。
 * 下限默认 targetLen/5（页级碎片防护）；**章级传 minRatio=1**（下限=目标长，
 * 整章一段是常态）—— 两者是同一函数的两档用法，见 splitSpeakSegments 注释。
 */

/** 播放状态。paused 与 stopped 的区别：paused 保留游标可续，stopped 游标归零 */
export type SpeakState = 'idle' | 'speaking' | 'paused' | 'stopped';

/** 句子边界字符（命中时优先在此处断段，朗读听感不断句） */
const SENTENCE_ENDERS: string[] = ['。', '！', '？', '；', '…', '!', '?', ';'];
/** 换行也是天然段界（章节内的空行分段） */
const LINE_BREAK: string = '\n';

/** 页级目标段长（保留：splitSpeakSegments 默认值，单测与调试用） */
export const SPEAK_SEGMENT_TARGET: number = 500;

/**
 * 章级目标段长（2026-10-18 起 Reader 的实际用量）。
 * 官方单次 speak 上限 10,000 字符 —— 8000 留 20% 防御余量
 * （上限附近的边缘行为没验证过，不贴边）。
 */
export const SPEAK_CHAPTER_TARGET: number = 8000;

/** 收段下限比例：不足 targetLen/5 的碎句不收段（防句句切的碎片化） */
const MIN_RATIO: number = 5;

/** 续读/跳转时向前找句界的最大回退字数（找不到就地切：中点好过硬回退） */
const RESUME_BACKTRACK: number = 120;

/** buf 内最后一个句界字符的下标；没有返回 -1 */
function lastBoundaryIndex(buf: string): number {
  for (let i: number = buf.length - 1; i >= 0; i--) {
    const ch: string = buf[i];
    if (ch === LINE_BREAK || SENTENCE_ENDERS.indexOf(ch) >= 0) {
      return i;
    }
  }
  return -1;
}

/** 数字判断（英文句点转换用：小数点/缩写点不转，见 normalizeForTts） */
function isAsciiDigit(ch: string): boolean {
  return ch >= '0' && ch <= '9';
}

/**
 * TTS 文本规范化（纯函数，**逐字符等长替换**）。
 *
 * 为什么需要（党哥 2026-10-19 实听反馈）：单引号对话嵌套（'……'）与英文标点
 * （, . : ;）会让离线 TTS 出问题 —— 读出多余发音、停顿位置诡异，甚至合成异常。
 * 离线引擎的文本前端只认中文标点体系，英文标点不在其处理范围内。
 *
 * 规则（全部等长，offset 映射 1:1 —— Reader 用**原始文本**的字符偏移 seekTo，
 * 长度一变定位全错，这是硬约束）：
 *   1. 引号类（中英文单/双引）→ 空格：TTS 读标点没有意义，单引号更是合成雷区；
 *   2. 破折号（— –）→ 空格：同上；
 *   3. 英文标点 → 中文等价（, → ，  : → ：  ; → ；  ! → ！  ? → ？）；
 *   4. 英文句点 . → 。，**数字相邻的保留**（3.14 / Mr. 这类小数点与缩写点，
 *      中文文本里小数点就是靠 . 表达的，转了会把"三点一四"读崩）；
 *   5. 其余原样返回（含中文标点、换行、省略号）。
 */
export function normalizeForTts(text: string): string {
  let out: string = '';
  for (let i: number = 0; i < text.length; i++) {
    const ch: string = text[i];
    // 1+2. 引号与破折号 → 空格（单引号 U+2018/2019、直引号 '、反引号变体 U+201B；
    //   双引号 U+201C/201D、直双引号 "）
    if (ch === '\u2018' || ch === '\u2019' || ch === '\'' || ch === '\u201b' ||
        ch === '\u201c' || ch === '\u201d' || ch === '"' ||
        ch === '\u2014' || ch === '\u2013') {
      out += ' ';
      continue;
    }
    // 3. 英文标点 → 中文等价
    if (ch === ',') {
      out += '，';
      continue;
    }
    if (ch === ':') {
      out += '：';
      continue;
    }
    if (ch === ';') {
      out += '；';
      continue;
    }
    if (ch === '!') {
      out += '！';
      continue;
    }
    if (ch === '?') {
      out += '？';
      continue;
    }
    // 4. 英文句点 → 中文句号（数字相邻保留：小数点/缩写点）
    if (ch === '.') {
      const prev: string = i > 0 ? text[i - 1] : '';
      const next: string = i + 1 < text.length ? text[i + 1] : '';
      if (isAsciiDigit(prev) || isAsciiDigit(next)) {
        out += '.';
      } else {
        out += '。';
      }
      continue;
    }
    out += ch;
  }
  return out;
}

/**
 * 把文本切成朗读段。
 *
 * 规则（见文件头「段的语义」）：
 *   - 空/纯空白文本 → 空数组（不产生朗读内容）；
 *   - 段界处且累积 ≥ targetLen/minRatio → 收段；
 *   - 累积到 targetLen → 最后句界回退切，无句界硬切；
 *   - 每段 strip 首尾空白，空段丢弃（TTS 收到空串会报错）。
 *
 * @param minRatio 收段下限的比例分母。默认 5（页级：不足 targetLen/5 的碎句
 *   继续累积，防句句切）；**章级传 1** —— 下限=目标长本身，即「不到 8000
 *   不切」，整章一段是常态（小段接缝是三大听感问题的总根因，findings §16.9）。
 */
export function splitSpeakSegments(text: string, targetLen: number = SPEAK_SEGMENT_TARGET,
  minRatio: number = MIN_RATIO): string[] {
  const out: string[] = [];
  if (text.length === 0 || targetLen <= 0) {
    return out;
  }
  const minLen: number = Math.max(1, Math.floor(targetLen / Math.max(1, minRatio)));
  let buf: string = '';
  let i: number = 0;
  while (i < text.length) {
    const ch: string = text[i];
    buf += ch;
    i++;
    const isBoundary: boolean = ch === LINE_BREAK || SENTENCE_ENDERS.indexOf(ch) >= 0;
    if (buf.length >= targetLen) {
      // 超目标长。恰好踩到句界 → 整段收（长度 ≤ targetLen）；否则回退切/硬切
      if (isBoundary) {
        out.push(buf.trim());
        buf = '';
      } else {
        const cut: number = lastBoundaryIndex(buf);
        if (cut > 0) {
          out.push(buf.substring(0, cut + 1).trim());
          buf = buf.substring(cut + 1);
        } else {
          out.push(buf.trim()); // 无句界（超长单句）→ 硬切兜底
          buf = '';
        }
      }
    } else if (isBoundary && buf.length >= minLen) {
      out.push(buf.trim());
      buf = '';
    }
  }
  if (buf.trim().length > 0) {
    out.push(buf.trim());
  }
  // 过滤边界/空白产生的空段（TTS 收到空串会报错，且浪费一次 speak 回调）
  const clean: string[] = [];
  for (let k: number = 0; k < out.length; k++) {
    if (out[k].length > 0) {
      clean.push(out[k]);
    }
  }
  return clean;
}

/**
 * 每段在**原文**中的起始下标（切段时 strip 过，偏移必须单独记录）。
 * 顺序 indexOf 查找：段落文本可能重复，从上一段结束处接着找不会错位。
 */
function computeSegOffsets(text: string, segs: string[]): number[] {
  const offs: number[] = [];
  let pos: number = 0;
  for (let k: number = 0; k < segs.length; k++) {
    const idx: number = text.indexOf(segs[k], pos);
    if (idx < 0) {
      offs.push(pos); // 理论不出现（段来自原文子串）；兜底不错位
    } else {
      offs.push(idx);
      pos = idx + segs[k].length;
    }
  }
  return offs;
}

/**
 * 纯函数：段内续读切点 —— offset 之前最近的句界（回退 ≤ RESUME_BACKTRACK）。
 * 返回的切点语义：从返回下标处**接着读**（句界字符本身归上一段，不重复读）。
 *   - offset 处字符即句界 → 返回 offset + 1（句号后开读）；
 *   - 回退范围内找到句界 → 句界下标 + 1；
 *   - 回退超限（病态长句中部）→ 返回 offset 本身（宁中点，不硬回退一大截）。
 */
export function resumeCutIndex(text: string, offset: number): number {
  if (offset <= 0) {
    return 0;
  }
  if (offset > text.length) {
    return text.length;
  }
  const limit: number = Math.max(0, offset - RESUME_BACKTRACK);
  for (let i: number = offset; i >= limit; i--) {
    if (i < text.length) {
      const ch: string = text[i];
      if (ch === LINE_BREAK || SENTENCE_ENDERS.indexOf(ch) >= 0) {
        return Math.min(i + 1, text.length);
      }
    }
  }
  return offset;
}

/**
 * 纯函数：语速 EMA 更新（chars/sec，中文 TTS 常速约 4~6 字/秒）。
 * 段播完时用「段字符数 / 实际播放秒数」校准 —— 时间估算的位置准不准全靠它。
 * 防御：秒数 ≤ 0.3 的样本是噪声（瞬段/瞬停），不采纳；结果夹在 [2, 12]。
 */
export function updateCharsPerSec(prev: number, chars: number, seconds: number): number {
  if (chars <= 0 || seconds <= 0.3) {
    return prev;
  }
  const sample: number = chars / seconds;
  const next: number = prev * 0.6 + sample * 0.4;
  if (next < 2) {
    return 2;
  }
  if (next > 12) {
    return 12;
  }
  return next;
}

/**
 * 朗读队列 + 状态机。
 *
 * 生命周期（TtsEngine 按此驱动）：
 *   loadChapter(text) → seekTo(offset) 定位 → markSpeaking → speak → onComplete
 *   → advance() 取下一段 → …→ advance() 返回 null（全部读完，自动转 stopped）
 * 中途 pause() → resume() 从暂停点续读（seekTo 句界回退，见 resume 注释）。
 */
export class SpeakQueue {
  private segs: string[] = [];
  /** segs[i] 在原文中的起始下标（与 segs 等长；load 时重算） */
  private segOffsets: number[] = [];
  private cursor: number = -1; // -1 = 未开始；>=0 = 当前段序号
  private playState: SpeakState = 'idle';

  /**
   * 载入新文本并复位（换章/换页必调；不清就是新旧文本混读）。
   * 入口做 TTS 规范化（normalizeForTts：英文标点→中文、引号→空格）——
   * 等长替换，所以 segOffsets 与调用方的原始文本偏移一一对应，seekTo 不用换算。
   */
  load(text: string, targetLen: number = SPEAK_SEGMENT_TARGET, minRatio: number = MIN_RATIO): number {
    const norm: string = normalizeForTts(text);
    this.segs = splitSpeakSegments(norm, targetLen, minRatio);
    this.segOffsets = computeSegOffsets(norm, this.segs);
    this.cursor = -1;
    this.playState = 'idle';
    return this.segs.length;
  }

  /** 载入**整章**并切段（章级朗读入口；默认目标 8000，官方上限 10000 的 4/5） */
  loadChapter(text: string): number {
    // minRatio=1：下限=目标长 —— 整章一段是常态，只在逼近 8000 时才切
    return this.load(text, SPEAK_CHAPTER_TARGET, 1);
  }

  /** 总段数（UI 显示 段 x/y 用） */
  get total(): number {
    return this.segs.length;
  }

  /** 当前段序号（0-based）；-1 = 未开始 */
  get cursorIndex(): number {
    return this.cursor;
  }

  /** 当前段在原文中的起始下标；cursor 无效返回 -1 */
  segmentOffset(index: number): number {
    if (index < 0 || index >= this.segOffsets.length) {
      return -1;
    }
    return this.segOffsets[index];
  }

  /** 当前段字符数；cursor 无效返回 -1（位置估算用） */
  currentLength(): number {
    if (this.cursor < 0 || this.cursor >= this.segs.length) {
      return -1;
    }
    return this.segs[this.cursor].length;
  }

  get state(): SpeakState {
    return this.playState;
  }

  /** idle/stopped → speaking（seekTo 定位后由调用方显式置位） */
  markSpeaking(): void {
    if (this.playState === 'idle' || this.playState === 'stopped') {
      this.playState = 'speaking';
    }
  }

  /**
   * 开始播放（idle/stopped → speaking）。
   * 返回第一段文本；空文本返回 null（调用方应视为"无可读内容"）。
   */
  begin(): string | null {
    if (this.segs.length === 0) {
      return null;
    }
    this.cursor = 0;
    this.playState = 'speaking';
    return this.segs[0];
  }

  /**
   * 当前段播完，取下一段。
   * 返回 null = 全部播完（状态已自动转 stopped，游标保留在最后一段，
   * UI 可显示"已读完"；重新 begin() 会回到第一段）。
   */
  advance(): string | null {
    if (this.playState !== 'speaking') {
      return null;
    }
    const next: number = this.cursor + 1;
    if (next >= this.segs.length) {
      this.playState = 'stopped';
      return null;
    }
    this.cursor = next;
    return this.segs[next];
  }

  /** speaking → paused（游标不动） */
  pause(): void {
    if (this.playState === 'speaking') {
      this.playState = 'paused';
    }
  }

  /**
   * paused → speaking，返回**当前段**（从头重读）。
   * ⚠️ 章级段长下这个语义已不适用（8000 字段重听 = 回退几十分钟）——
   * TtsEngine.resumeNow 走的是 seekTo(pausedOffset) 句界回退续读。
   * 本方法保留给"从没定位过就暂停"的防御路径。
   */
  resume(): string | null {
    if (this.playState !== 'paused' || this.cursor < 0 || this.cursor >= this.segs.length) {
      return null;
    }
    this.playState = 'speaking';
    return this.segs[this.cursor];
  }

  /** 停止并复位游标（stopped → 再次 begin 从第一段来） */
  stop(): void {
    this.playState = 'stopped';
    this.cursor = -1;
  }

  /**
   * 跳转到章内字符偏移 offset 处续读（纯文本手术，不碰状态机）。
   *
   * 做三件事：① 找 offset 所在段并置游标；② 段内按 resumeCutIndex 切在
   * **句界**上（不切碎句子）；③ 把当前段替换为切点后的尾部，同步更新
   * segOffsets（位置估算的基数）。返回应 speak 的文本。
   *
   * 边界：
   *   - offset ≤ 段首 → 整段读（不切）；
   *   - offset ≥ 段尾 → 下一段整段（最后一段之后返回 null）；
   *   - 队列空 → null。
   * 状态由调用方处置：TtsEngine.seekTo  paused 时只手术不开读（恢复点后移），
   * 其余情况手术后 markSpeaking + speak。
   */
  seekTo(offset: number): string | null {
    if (this.segs.length === 0 || offset < 0) {
      return null;
    }
    // 找所在段：segOffsets[k] <= offset < segOffsets[k+1]（offset 超尾部 → 最后段）
    let i: number = this.segs.length - 1;
    for (let k: number = 0; k < this.segs.length; k++) {
      if (this.segOffsets[k] > offset) {
        i = k - 1;
        break;
      }
      i = k;
    }
    if (i < 0) {
      i = 0;
    }
    this.cursor = i;
    const segStart: number = this.segOffsets[i];
    const segText: string = this.segs[i];
    const inner: number = offset - segStart;
    if (inner <= 0) {
      return segText; // 段首或更前：整段读
    }
    if (inner >= segText.length) {
      // 段尾或更后：下一段整段；没有下一段 = 读完了
      if (i + 1 < this.segs.length) {
        this.cursor = i + 1;
        return this.segs[i + 1];
      }
      return null;
    }
    const cut: number = resumeCutIndex(segText, inner);
    if (cut <= 0 || cut >= segText.length) {
      return segText; // 回退到段首/切点在尾部：整段读
    }
    const tail: string = segText.substring(cut);
    this.segs[i] = tail;
    this.segOffsets[i] = segStart + cut;
    return tail;
  }
}
