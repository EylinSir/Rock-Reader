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
import { splitSpeakSegments, SpeakQueue, SPEAK_SEGMENT_TARGET } from '../entry/src/main/ets/engine/tts/SpeakQueue.ets';

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
