/**
 * 跨层共享的少量类型（book / 进度）
 * 设计依据：docs/v1-design.md §4 数据模型
 */

export interface BookRecord {
  id: string;
  title: string;
  author: string;
  /** 'txt' | 'epub' */
  format: string;
  /** 沙箱内绝对路径 */
  path: string;
  size: number;
  addedAt: number;
  lastReadAt: number;
  /** 分组名（空串或空值按「未分组」处理，见 engine/shelf/ShelfRules） */
  groupName: string;
}

/** 书架列表项：书 + 阅读进度（0~1） */
export interface ShelfItem {
  book: BookRecord;
  percent: number;
}

export interface ReadingProgress {
  bookId: string;
  chapterIndex: number;
  /** 章内字符偏移（页表用它反查页码） */
  charOffset: number;
  /** 0~1 */
  percent: number;
  updatedAt: number;
}

/**
 * 阅读页写完进度库后**推给书架的进度快照**（经 AppStorage 的 'progressSaved' 键）。
 *
 * 为什么需要它：只靠"onPageShow 重查库"的链路在 **API 24 真机上不刷新**
 * （华为 1.0.1 审核反馈，nova 14 Pro / Pura 80 Ultra 实测）。
 * 收到快照后书架**直接改本地 @State** → ArkUI 立即重渲染：不查库、不等 onPageShow、不依赖版本行为。
 */
export interface ProgressSnapshot {
  bookId: string;
  /** 0~1 */
  percent: number;
}

export interface ChapterRow {
  bookId: string;
  index: number;
  title: string;
  /** TXT：该章在全文中的字符区间（EPUB 不用，置 0） */
  startChar: number;
  endChar: number;
  /** TXT：UTF-8 字节偏移（EPUB 不用，置 0） */
  startByte: number;
  endByte: number;
  /** EPUB：该章在 zip 内的路径；TXT 为空串 */
  href: string;
}
