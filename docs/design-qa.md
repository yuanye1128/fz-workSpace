# fz-workSpace Design QA

> 更新时间：2026-08-11。原截图记录保留为 v1.0 历史证据；当前详情弹窗已按 CR-008 从毛玻璃调整为实色面板和半透明遮罩，需以后续截图作为最新视觉证据。

- Source visual truth: `assets/devflow-v1-visual-baseline.png`
- Implementation screenshots:
  - `../qa-main-light.png`
  - `../qa-modal-light.png`
  - `../qa-main-dark.png`
  - `../qa-modal-dark.png`
- Combined comparison evidence:
  - `../qa/compare-main-light.png`
  - `../qa/compare-modal-light.png`
- App window viewport: 1088 × 768 points at the captured desktop scale.
- Source pixels: 2048 × 1376. Implementation pixels: 1088 × 768 for each capture.
- Normalization: the source was scaled to 1088 × 768 before horizontal comparison; implementation captures were not rescaled.
- States: light dashboard, light ticket modal, dark dashboard, dark ticket modal.

## Findings

历史 v1.0 截图对比中没有遗留 P0、P1 或 P2 问题。CR-008 已改变弹窗材质，当前实现已通过编译，但仍需更新截图后重新确认最新视觉结果。

- Fonts and typography: native macOS system typography preserves the source hierarchy, weights, truncation, and compact desktop density. Chinese labels and card summaries remain legible in both themes.
- Spacing and layout rhythm: sidebar proportions, toolbar hierarchy, responsive grid, card padding, selected-card border, and filter spacing follow the current specification. The source's fixed right panel is intentionally replaced by the centered modal required by CR-001, allowing the grid to occupy the available width.
- Colors and tokens: the light palette uses a clean white elevated surface; the dark palette uses a dedicated elevated surface. The modal backdrop is a plain translucent black overlay, with no frosted-glass material or whole-page blur.
- Image quality and assets: the target is UI-led and contains no required photographic or illustrative content. Standard controls use consistent SF Symbols; the user avatar area correctly falls back to a generic user icon because no real profile asset is available.
- Copy and content: the visible navigation, ticket fields, statuses, filters, repository controls, AI provider choices, and workflow labels match the product specification.
- Interaction states: selected card, disabled actions, modal backdrop, close control, repository-empty prompt, theme switching, search field, modal focus, refresh rotation and new-ticket notification state are represented by dedicated UI state.
- Responsiveness: the sidebar stays fixed at 250pt; toolbar actions retain their size while the search field yields width first. The grid uses the remaining central width, keeps 16pt row/column spacing and supports at most four columns with no card overlap.
- Accessibility: controls expose semantic button, radio-button, menu-button, and text-field roles; ticket cards include descriptive accessibility labels and secondary actions; status is expressed with text as well as color.

## Comparison History

### Iteration 1

- Earlier finding [P1 behavior]: Escape did not reliably route the close action into the modal while the background search field retained focus.
- Earlier finding [P1 safety]: a cancelled historical work item could bypass the unsaved-helper-text warning.
- Fixes made: moved keyboard focus into the modal, added an app-level Escape event route, unified backdrop and keyboard close requests, and based the warning on the visible configuration state rather than the existence of an old work item.
- Post-fix evidence: the modal opens centered with focus inside it; right-top close displays the unsaved-input confirmation, and Escape closes the focused modal. Background interaction remains blocked while the modal is visible.

### Iteration 2

- Earlier finding [P2 workflow clarity]: the partial-completion coordinator supported ticket-update retry, but the report UI did not expose it.
- Earlier finding [P2 safety]: discarding AI changes immediately restored files without a dedicated confirmation.
- Fixes made: added “仅重试工单更新” for partial completion and a destructive confirmation describing file restoration and skipped external side effects.
- Post-fix evidence: the code compiles, tests pass, and the report view renders stage-specific status and actions.

## Focused Region Comparison

The modal remains the focused region. The right-panel content from the visual baseline—ticket metadata, repository, branch, AI selection, helper context, actions, and workflow—is preserved inside the centered modal. CR-008 supersedes the older frosted-glass treatment with a clean solid surface, semantic border, shadow and plain translucent backdrop.

## Follow-up Polish

- [P3] Replace the generic user icon with the authenticated knowledge-base avatar when that data becomes safely available.

final result: implementation and build passed; CR-008 screenshots should replace the historical modal screenshots during the next visual capture pass
