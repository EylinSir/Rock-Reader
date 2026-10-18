/**
 * 朗读队列纯逻辑单测（CI 可跑，无模拟器依赖）
 * 覆盖：splitSpeakSegments 切段规则 + SpeakQueue 状态机
 *
 * 段语义（ SpeakQueue.ets 文件头）：段 = 一两句话 ~10s 一听；
 * 目标长 targetLen（默认 500），收段下限 targetLen/5，句界收段，超长回退切/硬切。
 * 测试里大量用小 targetLen 强制切分 —— 测的是规则，不是默认值。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  splitSpeakSegments,
  SpeakQueue,
  SPEAK_SEGMENT_TARGET,
  SPEAK_CHAPTER_TARGET,
  resumeCutIndex,
  updateCharsPerSec,
  normalizeForTts
} from '../entry/src/main/ets/engine/tts/SpeakQueue.ets';

// ---------------------------------------------------------------
// splitSpeakSegments
// ---------------------------------------------------------------

test('split：空文本/纯空白 → 空数组（TTS 不收空串）', () => {
  assert.deepEqual(splitSpeakSegments(''), []);
  assert.deepEqual(splitSpeakSegments('   \n\t  '), []);
});

test('split：短文本不足下限 → 合成一段（防句句切的碎片化）', () => {
  assert.deepEqual(splitSpeakSegments('春眠不觉晓。'), ['春眠不觉晓。']);
  assert.deepEqual(splitSpeakSegments('第一句。第二句！第三句？', 100), ['第一句。第二句！第三句？']);
});

test('split：句界且过下限 → 按句收段', () => {
  assert.deepEqual(splitSpeakSegments('第一句。第二句！第三句？', 8), ['第一句。', '第二句！', '第三句？']);
});

test('split：中英文标点都识别', () => {
  assert.deepEqual(splitSpeakSegments('Hello! Hi? Bye;', 10), ['Hello!', 'Hi?', 'Bye;']);
});

test('split：换行是段界', () => {
  assert.deepEqual(splitSpeakSegments('上一行\n下一行', 3), ['上一行', '下一行']);
});

test('split：段首尾空白被 strip', () => {
  // targetLen=100（minLen=20）：25 空格+'甲。' 过下限在句界收段，strip 掉前导空白
  assert.deepEqual(splitSpeakSegments(' '.repeat(25) + '甲。  \n\n  乙。', 100), ['甲。', '乙。']);
});

test('split：纯空白段界产生的空段被丢弃（TTS 不收空串）', () => {
  // 600 个换行 targetLen=500：第一段在 500 处 push 空串（trim 后为空）→ 必须被过滤
  assert.deepEqual(splitSpeakSegments('\n'.repeat(600), 500), []);
});

test('split：超长无标点单句 → 硬切，且每段不超 targetLen', () => {
  const text = 'x'.repeat(2500);
  const segs = splitSpeakSegments(text, 1000);
  assert.equal(segs.length, 3);
  for (const s of segs) {
    assert.ok(s.length <= 1000, `段超长: ${s.length}`);
  }
  // 硬切不漏字：拼回去等于原文（strip 不影响纯 x）
  assert.equal(segs.join(''), text);
});

test('split：超长有标点 → 最后句界回退切，不硬断句子', () => {
  const body = '字'.repeat(900);
  const segs = splitSpeakSegments(body + '。尾巴。', 1000);
  assert.equal(segs.length, 2);
  assert.equal(segs[0], body + '。');
  assert.equal(segs[1], '尾巴。');
});

test('split：默认 targetLen = 500（一听辑；官方上限 10000 的 1/20）', () => {
  const segs = splitSpeakSegments('好。'.repeat(3000)); // 6000 字
  // 每段 ~250 字（500/2）→ ~24 段；粗断言防过度耦合
  assert.ok(segs.length >= 15, `段数异常: ${segs.length}`);
  for (const s of segs) {
    assert.ok(s.length <= SPEAK_SEGMENT_TARGET, `段超限: ${s.length}`);
  }
  assert.equal(segs.join(''), '好。'.repeat(3000), '不漏字');
});

test('split：真实中文章节按句界切，段长波动受控且不漏字', () => {
  // 模拟真实章节：每句约 10 字，共约 1.2 万字
  let chapter = '';
  for (let i = 0; i < 1000; i++) {
    chapter += '这是第' + i + '句测试文本。';
  }
  const segs = splitSpeakSegments(chapter);
  assert.ok(segs.length >= 20, '1.2 万字至少 20 段');
  for (const s of segs) {
    assert.ok(s.length <= SPEAK_SEGMENT_TARGET, `段超限: ${s.length}`);
    assert.ok(s.endsWith('。'), '句界收段的段尾必须是句号');
  }
  assert.equal(segs.join(''), chapter, '不漏字');
});

test('split：targetLen 非法值 → 空数组（防御）', () => {
  assert.deepEqual(splitSpeakSegments('有内容。', 0), []);
  assert.deepEqual(splitSpeakSegments('有内容。', -5), []);
});

// ---------------------------------------------------------------
// SpeakQueue 状态机（小 targetLen 强制多段）
// ---------------------------------------------------------------

test('queue：空文本 begin → null（调用方提示无可读内容）', () => {
  const q = new SpeakQueue();
  q.load('');
  assert.equal(q.begin(), null);
  assert.equal(q.total, 0);
  assert.equal(q.state, 'idle');
});

test('queue：完整播放生命周期 begin→advance→…→stopped', () => {
  const q = new SpeakQueue();
  assert.equal(q.load('甲。乙。丙。', 4), 3);
  assert.equal(q.state, 'idle');
  assert.equal(q.begin(), '甲。');
  assert.equal(q.state, 'speaking');
  assert.equal(q.cursorIndex, 0);
  assert.equal(q.advance(), '乙。');
  assert.equal(q.cursorIndex, 1);
  assert.equal(q.advance(), '丙。');
  assert.equal(q.cursorIndex, 2);
  assert.equal(q.advance(), null, '读完返回 null');
  assert.equal(q.state, 'stopped', '读完自动 stopped');
  assert.equal(q.cursorIndex, 2, 'stopped 保留游标（UI 可显示读完）');
  // 再 begin 回到第一段
  assert.equal(q.begin(), '甲。');
  assert.equal(q.cursorIndex, 0);
});

test('queue：pause 保留游标，resume 重读当前段', () => {
  const q = new SpeakQueue();
  q.load('甲。乙。丙。', 4);
  q.begin();
  q.advance(); // 到乙
  q.pause();
  assert.equal(q.state, 'paused');
  assert.equal(q.advance(), null, 'paused 态 advance 无效（防串态）');
  assert.equal(q.resume(), '乙。', 'resume 重读当前段');
  assert.equal(q.state, 'speaking');
});

test('queue：stop 复位游标', () => {
  const q = new SpeakQueue();
  q.load('甲。乙。', 4);
  q.begin();
  q.advance();
  q.stop();
  assert.equal(q.state, 'stopped');
  assert.equal(q.cursorIndex, -1, 'stop 后游标归零');
  assert.equal(q.begin(), '甲。', '再 begin 从第一段来');
});

test('queue：load 复位播放态（防新旧文本混读）', () => {
  const q = new SpeakQueue();
  q.load('甲。乙。', 4);
  q.begin();
  q.advance();
  q.load('新。文。', 4);
  assert.equal(q.state, 'idle', 'load 必须复位状态');
  assert.equal(q.cursorIndex, -1);
  assert.equal(q.total, 2);
  assert.equal(q.begin(), '新。');
});

test('queue：非 speaking 态 advance 返回 null', () => {
  const q = new SpeakQueue();
  q.load('甲。', 4);
  assert.equal(q.advance(), null);
  q.begin();
  q.pause();
  assert.equal(q.advance(), null);
});

test('queue：resume 只在 paused 态有效', () => {
  const q = new SpeakQueue();
  q.load('甲。', 4);
  assert.equal(q.resume(), null, 'idle 态 resume 无效');
  q.begin();
  assert.equal(q.resume(), null, 'speaking 态 resume 无效');
});

// ---------------------------------------------------------------
// 章级朗读（2026-10-18 修订：段 = 合成单元，默认 8000/段，findings §16.9）
// ---------------------------------------------------------------

test('chapter：短章（绝大多数章节）→ 一段读完，零接缝', () => {
  const q = new SpeakQueue();
  // 3000 字段落：远低于 8000 目标 → 最后句界收一段
  let text = '';
  for (let i = 0; i < 300; i++) {
    text += '这是第' + i + '句话。';
  }
  assert.equal(q.loadChapter(text), 1);
  assert.equal(q.begin(), text);
  assert.equal(q.advance(), null, '一段读完即整章读完');
  assert.equal(q.state, 'stopped');
});

test('chapter：超长章 → 多段但每段 ≤ 8000 且句界收段、不漏字', () => {
  const q = new SpeakQueue();
  let text = '';
  for (let i = 0; i < 1200; i++) {
    text += '这是第' + i + '句话。';
  }
  const n: number = q.loadChapter(text);
  assert.ok(n >= 2, `1.2 万字应切 2 段以上，实际 ${n}`);
  assert.ok(q.segmentOffset(0) === 0, '首段从章首开始');
  for (let k = 0; k < n; k++) {
    const off: number = q.segmentOffset(k);
    assert.ok(off >= 0);
    if (k > 0) {
      assert.ok(off > q.segmentOffset(k - 1), '段偏移单调递增');
    }
  }
  // 切段规则同 splitSpeakSegments：章级 minRatio=1，8000 目标下段长 ≤ 8000
  const segs: string[] = splitSpeakSegments(text, SPEAK_CHAPTER_TARGET, 1);
  assert.equal(n, segs.length);
  for (const s of segs) {
    assert.ok(s.length <= SPEAK_CHAPTER_TARGET, `段超限: ${s.length}`);
  }
  // 章级语义验证：第一段必须逼近 8000 才切（不是 1600 就切）
  assert.ok(segs[0].length > 7000, `章级首段应尽量长: ${segs[0].length}`);
});

test('chapter：段偏移与文本对得上（位置估算的基数）', () => {
  const q = new SpeakQueue();
  const text = '甲。'.repeat(100) + '乙。'.repeat(100) + '丙。'.repeat(100); // 600 字
  q.loadChapter(text);
  // 600 字 < 8000 → 一段；偏移 0
  assert.equal(q.total, 1);
  assert.equal(q.segmentOffset(0), 0);
  assert.equal(q.currentLength(), -1, '未 begin 时无当前段');
  q.begin();
  assert.equal(q.currentLength(), text.length);
});

test('seekTo：段内偏移 → 切在句界后开读，偏移基数同步', () => {
  const q = new SpeakQueue();
  // 下标：春0眠1不2觉3晓4，5处6处7闻8啼9鸟10。11夜12来13...
  const text = '春眠不觉晓，处处闻啼鸟。夜来风雨声，花落知多少。';
  q.loadChapter(text);
  const tail: string | null = q.seekTo(13); // 「夜来」中间 → 回退到 index11 的句号后
  assert.equal(tail, '夜来风雨声，花落知多少。');
  assert.equal(q.cursorIndex, 0);
  assert.equal(q.segmentOffset(0), 12, '段起点后移到切点（估算连续）');
});

test('seekTo：偏移处即句界 → 句号后开读（不吃句号）', () => {
  const q = new SpeakQueue();
  const text = '春眠不觉晓，处处闻啼鸟。夜来风雨声，花落知多少。';
  q.loadChapter(text);
  const tail: string | null = q.seekTo(11); // 正踩第一个句号
  assert.equal(tail, '夜来风雨声，花落知多少。');
  assert.equal(q.segmentOffset(0), 12);
});

test('seekTo：回退超限（病态长句中部）→ 就地切，不硬回退', () => {
  const q = new SpeakQueue();
  const text = '无标点的长句'.repeat(200); // 1400 字无句界
  q.loadChapter(text);
  const tail: string | null = q.seekTo(700); // 前后 120 字内都无句界
  assert.ok(tail !== null);
  assert.equal(tail, text.substring(700), '回退超限就地从 offset 切');
  assert.equal(q.segmentOffset(0), 700);
});

test('seekTo：段首偏移 → 整段读（不切）；负偏移防御 → null', () => {
  const q = new SpeakQueue();
  const text = '春眠不觉晓，处处闻啼鸟。夜来风雨声，花落知多少。';
  q.loadChapter(text);
  assert.equal(q.seekTo(0), text);
  assert.equal(q.seekTo(-5), null, '负偏移防御：返回 null 由调用方忽略');
});

test('seekTo：跨段偏移 → 落到目标段', () => {
  const q = new SpeakQueue();
  let text = '';
  for (let i = 0; i < 1200; i++) {
    text += '这是第' + i + '句话。';
  }
  const n: number = q.loadChapter(text);
  assert.ok(n >= 2);
  const midOff: number = q.segmentOffset(1) + 5; // 第二段中部
  const tail: string | null = q.seekTo(midOff);
  assert.ok(tail !== null);
  assert.equal(q.cursorIndex, 1);
  // 从第二段中部最近句界后开读（切点落在回退上限内）
  assert.ok((tail as string).length < 8000);
  assert.ok(q.segmentOffset(1) >= midOff - 120, '切点不早于回退上限前');
});

test('seekTo：偏移超全部段 → null（读完了）', () => {
  const q = new SpeakQueue();
  q.loadChapter('春眠不觉晓。');
  assert.equal(q.seekTo(99999), null);
});

test('seekTo：纯文本手术，不碰状态机（paused 保持 paused）', () => {
  const q = new SpeakQueue();
  const text = '春眠不觉晓，处处闻啼鸟。夜来风雨声，花落知多少。';
  q.loadChapter(text);
  q.begin();
  q.pause();
  q.seekTo(11);
  assert.equal(q.state, 'paused', '暂停中跳页只移恢复点，不开读');
  assert.equal(q.resume(), '夜来风雨声，花落知多少。', '继续从新位置读');
});

test('markSpeaking：idle/stopped → speaking；speaking/paused 不变', () => {
  const q = new SpeakQueue();
  q.loadChapter('甲。乙。');
  q.markSpeaking();
  assert.equal(q.state, 'speaking');
  q.pause();
  q.markSpeaking();
  assert.equal(q.state, 'paused', 'paused 不被 markSpeaking 冲掉');
  q.stop();
  q.markSpeaking();
  assert.equal(q.state, 'speaking');
});

test('resumeCutIndex：句界后开读 / 回退找句界 / 超限就地切', () => {
  // 下标：春0眠1不2觉3晓4。5夜6来7风8雨9声10。11
  assert.equal(resumeCutIndex('春眠不觉晓。夜来风雨声。', 0), 0, 'offset 0 → 0');
  assert.equal(resumeCutIndex('春眠不觉晓。夜来风雨声。', 5), 6, 'offset 处即句号 → 句号后开读');
  assert.equal(resumeCutIndex('春眠不觉晓。夜来风雨声。', 8), 6, '回退到句号后');
  assert.equal(resumeCutIndex('春眠不觉晓。夜来风雨声。', 100), 12, '超长 offset 夹到文长');
  const noPunct = '无标点长句'.repeat(100);
  assert.equal(resumeCutIndex(noPunct, 500), 500, '回退超限就地切');
  assert.equal(resumeCutIndex(noPunct, 500), resumeCutIndex(noPunct, 500), '纯函数可重复');
});

test('updateCharsPerSec：EMA 校准 / 脏值防御 / 夹取', () => {
  // 4000 字播了 900 秒 ≈ 4.44 字/秒：向默认 4.5 收敛
  const cps: number = updateCharsPerSec(4.5, 4000, 900);
  assert.ok(cps > 4.3 && cps < 4.7, `EMA 结果异常: ${cps}`);
  // 瞬段（秒数 ≤ 0.3）是噪声，不采纳
  assert.equal(updateCharsPerSec(4.5, 10, 0.1), 4.5);
  // 非正 chars/seconds 不回退
  assert.equal(updateCharsPerSec(4.5, 0, 10), 4.5);
  assert.equal(updateCharsPerSec(4.5, 10, 0), 4.5);
  // 极端快/慢夹在 [2, 12]（EMA 收敛方向 + 夹取）
  assert.equal(updateCharsPerSec(11, 10000, 1), 12, '极端快 → 夹上限');
  assert.equal(updateCharsPerSec(2.5, 1, 100), 2, '极端慢 → 夹下限');
  // 单调收敛：持续同速率样本 → 逼近该速率
  let c: number = 4.5;
  for (let i = 0; i < 20; i++) {
    c = updateCharsPerSec(c, 500, 100); // 5 字/秒
  }
  assert.ok(Math.abs(c - 5) < 0.1, `EMA 应收敛到 5: ${c}`);
});

// ---------------------------------------------------------------
// TTS 文本规范化（党哥 2026-10-19 实听反馈：单引号/英文标点出问题）
// ---------------------------------------------------------------

test('normalize：引号类（中英文单双引）→ 空格', () => {
  assert.equal(normalizeForTts("他说'是的'"), '他说 是的 ');
  assert.equal(normalizeForTts('他说"好的"'), '他说 好的 ');
  assert.equal(normalizeForTts("It's fine"), 'It s fine');
  // 直双引号与弯引号一视同仁
  assert.equal(normalizeForTts('\u201c引用\u201d'), ' 引用 ');
});

test('normalize：破折号 → 空格', () => {
  assert.equal(normalizeForTts('话没说完——'), '话没说完  ');
  assert.equal(normalizeForTts('a–b'), 'a b');
});

test('normalize：英文标点 → 中文等价', () => {
  assert.equal(normalizeForTts('Hello, world: ok; fine! really?'), 'Hello， world： ok； fine！ really？');
  assert.equal(normalizeForTts('Mr. Smith went home.'), 'Mr。 Smith went home。');
});

test('normalize：数字间的英文句点保留（小数点/缩写点）', () => {
  assert.equal(normalizeForTts('圆周率是3.14'), '圆周率是3.14');
  assert.equal(normalizeForTts('版本1.2.3发布'), '版本1.2.3发布');
  assert.equal(normalizeForTts('a.b'), 'a。b', '非数字邻点仍转换');
});

test('normalize：等长性是硬约束（Reader 用原始偏移 seekTo）', () => {
  const samples: string[] = [
    "他说'是的'，然后\"走了\"——离开。",
    'Hello, world! Test: ok; done?',
    '3.14 和 Mr. Smith 与 a.b 混排',
    '\u201c\u2018弯引号\u2019\u201d直引号"',
    ''
  ];
  for (const s of samples) {
    const n: string = normalizeForTts(s);
    assert.equal(n.length, s.length, `等长被破坏: ${s}`);
  }
  // 中文标点原样不动
  assert.equal(normalizeForTts('春眠不觉晓，处处闻啼鸟。'), '春眠不觉晓，处处闻啼鸟。');
});

test('normalize+load：seekTo 偏移在含引号/英文标点的章节里依然对齐', () => {
  const q = new SpeakQueue();
  // 原文里 offset=k 的位置，规范化后必须还是同一句话（等长替换）
  const text = '甲说\'你好\'，然后离开了。乙说"再见"，也走了。丙还在原地。';
  q.loadChapter(text);
  assert.equal(q.total, 1);
  // 第一个中文句号在 offset 12（\'你好\'，然后离开了。→ 引号变空格但位置不变）
  const tail: string | null = q.seekTo(13);
  assert.ok(tail !== null);
  // 从 offset 13 回退找句界：句号在 12 → 从 13 开读 = '乙说"再见"，也走了。丙还在原地。'
  // （规范化后引号是空格）
  assert.equal(tail, '乙说 再见 ，也走了。丙还在原地。');
  assert.equal(q.segmentOffset(0), 13);
});
