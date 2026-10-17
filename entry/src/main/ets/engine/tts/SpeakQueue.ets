/**
 * 朗读队列（**纯逻辑**，单测覆盖）
 *
 * 职责：
 *   1. 把一段文本切成 TTS 能吃的"段" —— 单次 speak 上限 10,000 字符
 *      （官方文档），产品目标段长 500（远低于上限，防御性硬切只是兜底）；
 *   2. 维护播放游标与状态（idle / speaking / paused / stopped）。
 *
 * 为什么单独一层：TTS 的 IO（createEngine / speak）依赖 @kit.CoreSpeechKit，
 * 真机才能跑；切段和游标推进是纯逻辑 —— CI 无模拟器、本机无 TTS 能力
 * （模拟器实测无 TTS SA，findings §15），这层也必须可测（v1-design §9）。
 *
 * **段的语义**（2026-10-17 定，产品视角）：
 *   段 = 一两句话，约 10 秒一听。为什么不是"整章一段"：pause/resume 是**重读
 *   当前段**（CoreSpeechKit 无段内断点），整章一段意味着暂停后要从头听；
 *   为什么不是"一句一段"：speak 调用太碎，段间可能有切换停顿，且段号 x/y 失去
 *   阅读节奏感。500 字是"一听辑"体感与调用开销的折中。
 *
 * 切段规则（优先级从高到低）：
 *   1. 超目标长：有句界 → 最后句界后回退切；无句界 → 硬切（病态长句兜底）；
 *   2. 句界（。！？；… 与换行）且已累积 ≥ 下限（targetLen/5）→ 收段；
 *   3. 不足下限的碎句继续累积（防"句句切"的碎片化）。
 */

/** 播放状态。paused 与 stopped 的区别：paused 保留游标可续，stopped 游标归零 */
export type SpeakState = 'idle' | 'speaking' | 'paused' | 'stopped';

/** 句子边界字符（命中时优先在此处断段，朗读听感不断句） */
const SENTENCE_ENDERS: string[] = ['。', '！', '？', '；', '…', '!', '?', ';'];
/** 换行也是天然段界（章节内的空行分段） */
const LINE_BREAK: string = '\n';

/** 单段目标长度（一听辑 ~10s；官方上限 10,000 的 1/20，防御性硬切几乎不触发） */
export const SPEAK_SEGMENT_TARGET: number = 500;

/** 收段下限比例：不足 targetLen/5 的碎句不收段（防句句切的碎片化） */
const MIN_RATIO: number = 5;

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

/**
 * 把文本切成朗读段。
 *
 * 规则（见文件头「段的语义」）：
 *   - 空/纯空白文本 → 空数组（不产生朗读内容）；
 *   - 段界处且累积 ≥ targetLen/5 → 收段；
 *   - 累积到 targetLen → 最后句界回退切，无句界硬切；
 *   - 每段 strip 首尾空白，空段丢弃（TTS 收到空串会报错）。
 */
export function splitSpeakSegments(text: string, targetLen: number = SPEAK_SEGMENT_TARGET): string[] {
  const out: string[] = [];
  if (text.length === 0 || targetLen <= 0) {
    return out;
  }
  const minLen: number = Math.max(1, Math.floor(targetLen / MIN_RATIO));
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
 * 朗读队列 + 状态机。
 *
 * 生命周期（TtsEngine 按此驱动）：
 *   load(text) → begin() 取第一段 → speak → onComplete → advance() 取下一段
 *   → …→ advance() 返回 null（全部读完，自动转 stopped）
 * 中途 pause() → resume() 重读当前段（CoreSpeechKit 无段内断点，见 resume 注释）。
 */
export class SpeakQueue {
  private segs: string[] = [];
  private cursor: number = -1; // -1 = 未开始；>=0 = 当前段序号
  private playState: SpeakState = 'idle';

  /** 载入新文本并复位（换章/换页必调；不清就是新旧文本混读） */
  load(text: string, targetLen: number = SPEAK_SEGMENT_TARGET): number {
    this.segs = splitSpeakSegments(text, targetLen);
    this.cursor = -1;
    this.playState = 'idle';
    return this.segs.length;
  }

  /** 总段数（UI 显示 段 x/y 用） */
  get total(): number {
    return this.segs.length;
  }

  /** 当前段序号（0-based）；-1 = 未开始 */
  get cursorIndex(): number {
    return this.cursor;
  }

  get state(): SpeakState {
    return this.playState;
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
   * 为什么重读而不是段内续播：CoreSpeechKit 的 speak 是整段合成，
   * 没有段内进度回调（onData 只有音频流，无字符位置）→ 断点续播做不到，
   * 重读当前段是唯一诚实的语义。产品上可接受：一段 ≤500 字，重听不超过十几秒。
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
}
