package main

import (
	"charm.land/lipgloss/v2"
	vpkg "github.com/robinovitch61/viewport/viewport"
	"github.com/robinovitch61/viewport/viewport/item"
	"strings"
)

// ViewerLine is one rendered row in a drill-down viewer. Key is the stable
// identity used to preserve the cursor across refreshes. Unselectable rows are
// rendered as part of the viewport but skipped by cursor movement.
type ViewerLine struct {
	Key          string
	Text         string
	Target       target
	Unselectable bool
	KeepNext     bool
}

type viewerRefreshPolicy int

const (
	viewerPreserve viewerRefreshPolicy = iota
	viewerReset
	viewerBottom
)

type viewerObject struct {
	key       string
	lineIndex int
	line      ViewerLine
	lines     []string
	item      item.Item
}

func (o viewerObject) GetItem() item.Item { return o.item }

// Viewer owns the drill-down viewport state. Selection is item-based: a
// selectable ViewerLine owns any immediately following unselectable rows, so
// message bodies and diff previews render with their parent row while cursor
// movement still lands only on actionable rows.
type Viewer struct {
	lines          []ViewerLine
	objects        []viewerObject
	viewport       *vpkg.Model[viewerObject]
	cursor         int
	offset         int
	selectedObject int
	selectedKey    string
	followBottom   bool
	width          int
	height         int
}

func (v *Viewer) SetBounds(width, height int) {
	if width < 1 {
		width = 1
	}
	v.width = width
	v.height = viewerHeight(height)
	v.ensureViewport()
	if v.viewport != nil {
		v.viewport.SetWidth(v.width)
		v.viewport.SetHeight(v.viewportHeight())
		v.viewport.SetObjects(v.objects)
		v.syncViewportSelection()
	}
}

func (v *Viewer) SetLines(lines []ViewerLine, policy viewerRefreshPolicy, height int) {
	v.height = viewerHeight(height)
	v.ensureViewport()
	v.lines = lines
	v.objects = buildViewerObjects(lines, v.height)
	if len(v.objects) == 0 {
		v.cursor = 0
		v.offset = 0
		v.selectedObject = 0
		v.selectedKey = ""
		v.followBottom = false
		v.viewport.SetObjects(nil)
		return
	}

	next := v.selectedObject
	switch policy {
	case viewerReset:
		next = 0
		v.followBottom = false
	case viewerBottom:
		next = len(v.objects) - 1
		v.followBottom = true
	default:
		if v.followBottom {
			next = len(v.objects) - 1
		} else if idx, ok := v.objectIndexByKey(v.selectedKey); ok {
			next = idx
		} else if next >= len(v.objects) {
			next = len(v.objects) - 1
		}
	}

	v.selectedObject = max(0, min(next, len(v.objects)-1))
	v.cursor = v.objects[v.selectedObject].lineIndex
	v.followBottom = v.selectedObject == len(v.objects)-1
	v.updateSelectedKey()
	v.viewport.SetBottomSticky(v.followBottom)
	v.viewport.SetObjects(v.objects)
	v.syncViewportSelection()
	v.updateOffset()
}

func (v *Viewer) Move(delta, height int) {
	v.height = viewerHeight(height)
	v.ensureViewport()
	if len(v.objects) == 0 {
		v.cursor = 0
		v.offset = 0
		v.selectedObject = 0
		v.selectedKey = ""
		v.followBottom = false
		return
	}
	next := v.selectedObject + delta
	if next < 0 {
		next = 0
	}
	if next >= len(v.objects) {
		next = len(v.objects) - 1
	}
	v.selectedObject = next
	v.cursor = v.objects[v.selectedObject].lineIndex
	v.followBottom = v.selectedObject == len(v.objects)-1
	v.updateSelectedKey()
	v.viewport.SetBottomSticky(v.followBottom)
	v.syncViewportSelection()
	v.updateOffset()
}

func (v *Viewer) Reset(height int) {
	v.SetLines(v.lines, viewerReset, height)
}

func (v Viewer) TextLines() []string {
	out := make([]string, len(v.lines))
	for i, line := range v.lines {
		out[i] = line.Text
	}
	return out
}

func (v Viewer) View() string {
	if v.viewport == nil {
		return ""
	}
	lines := strings.Split(v.viewport.View(), "\n")
	if len(lines) > v.height {
		lines = lines[:v.height]
	}
	return strings.Join(lines, "\n")
}

func (v Viewer) SelectedLine() (ViewerLine, bool) {
	if v.selectedObject >= 0 && v.selectedObject < len(v.objects) {
		return v.objects[v.selectedObject].line, true
	}
	if v.cursor < 0 || v.cursor >= len(v.lines) {
		return ViewerLine{}, false
	}
	return v.lines[v.cursor], true
}

func (v Viewer) Cursor() int { return v.cursor }

func (v Viewer) Offset() int { return v.offset }

func (v Viewer) SelectedKey() string { return v.selectedKey }

func (v Viewer) Len() int { return len(v.lines) }

func (v Viewer) MaxScroll(height int) int {
	if len(v.lines) == 0 {
		return 0
	}
	return max(0, len(v.lines)-viewerHeight(height))
}

func (v *Viewer) SelectKey(key string, height int) bool {
	idx, ok := v.objectIndexByKey(key)
	if !ok {
		return false
	}
	v.height = viewerHeight(height)
	v.ensureViewport()
	v.selectedObject = idx
	v.cursor = v.objects[idx].lineIndex
	v.followBottom = idx == len(v.objects)-1
	v.updateSelectedKey()
	v.viewport.SetBottomSticky(v.followBottom)
	v.syncViewportSelection()
	v.updateOffset()
	return true
}

func (v *Viewer) ensureViewport() {
	if v.width < 1 {
		v.width = 80
	}
	if v.height < 1 {
		v.height = 1
	}
	if v.viewport != nil {
		return
	}
	styles := vpkg.DefaultStyles()
	styles.SelectedItemStyle = lipgloss.NewStyle().Background(cActBg)
	v.viewport = vpkg.New[viewerObject](
		v.width,
		v.viewportHeight(),
		vpkg.WithWrapText[viewerObject](true),
		vpkg.WithSelectionEnabled[viewerObject](true),
		vpkg.WithFooterEnabled[viewerObject](false),
		vpkg.WithProgressBarEnabled[viewerObject](false),
		vpkg.WithSelectionStyleOverridesItemStyle[viewerObject](false),
		vpkg.WithStyles[viewerObject](styles),
	)
	v.viewport.SetSelectionComparator(func(a, b viewerObject) bool {
		return a.key == b.key
	})
}

func (v *Viewer) syncViewportSelection() {
	if v.viewport == nil || len(v.objects) == 0 {
		return
	}
	v.viewport.SetSelectedItemIdx(v.selectedObject)
}

func (v *Viewer) updateOffset() {
	if v.viewport == nil || len(v.objects) == 0 {
		v.offset = 0
		return
	}
	top, lineOffset := v.viewport.GetTopItemIdxAndLineOffset()
	if top < 0 || top >= len(v.objects) {
		v.offset = 0
		return
	}
	v.offset = v.objects[top].lineIndex + lineOffset
}

func (v *Viewer) objectIndexByKey(key string) (int, bool) {
	if key == "" {
		return 0, false
	}
	for i, obj := range v.objects {
		if obj.key == key {
			return i, true
		}
	}
	return 0, false
}

func (v *Viewer) updateSelectedKey() {
	if line, ok := v.SelectedLine(); ok {
		v.selectedKey = line.Key
	} else {
		v.selectedKey = ""
	}
}

func buildViewerObjects(lines []ViewerLine, height int) []viewerObject {
	objects := make([]viewerObject, 0, len(lines))
	packUnselectable := height > 1
	for i, line := range lines {
		if line.Unselectable && len(objects) > 0 {
			if packUnselectable {
				last := &objects[len(objects)-1]
				last.lines = append(last.lines, line.Text)
				last.item = viewerItem(last.lines)
			}
			continue
		}
		obj := viewerObject{
			key:       line.Key,
			lineIndex: i,
			line:      line,
			lines:     []string{line.Text},
		}
		obj.item = viewerItem(obj.lines)
		objects = append(objects, obj)
	}
	return objects
}

func viewerItem(lines []string) item.Item {
	if len(lines) == 0 {
		return item.NewItem("")
	}
	if len(lines) == 1 {
		return item.NewItem(lines[0])
	}
	items := make([]item.SingleItem, len(lines))
	for i, line := range lines {
		items[i] = item.NewItem(line)
	}
	return item.NewMultiLineItem(items...)
}

func (v Viewer) viewportHeight() int {
	return viewerHeight(v.height) + 1
}

func viewerHeight(height int) int {
	if height < 1 {
		return 1
	}
	return height
}
