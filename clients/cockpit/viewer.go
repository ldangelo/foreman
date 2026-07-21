package main

import (
	"strings"

	"charm.land/bubbles/v2/key"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	fvpkg "github.com/robinovitch61/viewport/filterableviewport"
	vpkg "github.com/robinovitch61/viewport/viewport"
	"github.com/robinovitch61/viewport/viewport/item"
)

// ViewerLine is one rendered row in a drill-down viewer. Key is the stable
// identity used to preserve the cursor across refreshes. Unselectable rows are
// rendered as part of the viewport but skipped by cursor movement.
type ViewerLine struct {
	Key          string
	Text         string
	Target       target
	Detail       []string
	DetailFunc   func() []string
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
	lines           []ViewerLine
	objects         []viewerObject
	viewport        *vpkg.Model[viewerObject]
	filter          *fvpkg.Model[viewerObject]
	cursor          int
	offset          int
	selectedObject  int
	selectedKey     string
	followBottom    bool
	searchActive    bool
	width           int
	height          int
	xOffset         int
	wrapText        bool
	wrapTextSet     bool
	selectionPrefix string
}

func (v *Viewer) SetWrapText(wrap bool) {
	v.wrapText = wrap
	v.wrapTextSet = true
	if v.viewport != nil {
		v.viewport.SetWrapText(wrap)
	}
}

func (v *Viewer) SetSelectionPrefix(prefix string) {
	v.selectionPrefix = prefix
	if v.viewport != nil {
		v.viewport.SetStyles(v.styles())
	}
}

func (v *Viewer) SetBounds(width, height int) {
	if width < 1 {
		width = 1
	}
	v.width = width
	v.height = viewerHeight(height)
	v.ensureViewport()
	if v.filter != nil {
		v.filter.SetWidth(v.width)
		v.filter.SetHeight(v.viewportHeight())
		v.viewport.SetWrapText(v.wrapText)
		v.setObjects(v.objects)
		v.syncViewportSelection()
		v.applyXOffset()
	}
}

func (v *Viewer) SetLines(lines []ViewerLine, policy viewerRefreshPolicy, height int) {
	v.height = viewerHeight(height)
	v.ensureViewport()
	v.viewport.SetWrapText(v.wrapText)
	oldObjectCount := len(v.objects)
	v.lines = lines
	baseObjects := buildViewerObjects(lines, v.height, "")
	v.objects = baseObjects
	if len(v.objects) == 0 {
		v.cursor = 0
		v.offset = 0
		v.selectedObject = 0
		v.selectedKey = ""
		v.followBottom = false
		v.setObjects(nil)
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

	if len(v.objects) < oldObjectCount {
		v.viewport = nil
		v.filter = nil
		v.ensureViewport()
		v.viewport.SetWrapText(v.wrapText)
	}
	v.selectedObject = max(0, min(next, len(baseObjects)-1))
	v.cursor = v.objects[v.selectedObject].lineIndex
	v.followBottom = v.selectedObject == len(v.objects)-1
	v.updateSelectedKey()
	v.objects = buildViewerObjects(lines, v.height, v.selectedKey)
	v.filter.SetBottomSticky(false)
	v.setObjects(v.objects)
	v.syncViewportSelection()
	v.applyXOffset()
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
	v.rebuildObjectsForSelection()
	v.filter.SetBottomSticky(false)
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
	var rendered string
	if v.searchActive || v.Searching() {
		rendered = v.filter.View()
	} else {
		v.viewport.SetPreFooterLine("")
		rendered = v.viewport.View()
	}
	lines := strings.Split(rendered, "\n")
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

func (v Viewer) XOffset() int {
	if v.viewport == nil {
		return v.xOffset
	}
	return v.viewport.GetXOffsetWidth()
}

func (v *Viewer) Pan(delta int) {
	v.ensureViewport()
	if v.viewport == nil {
		return
	}
	v.viewport.SetXOffset(v.viewport.GetXOffsetWidth() + delta)
	v.xOffset = v.viewport.GetXOffsetWidth()
}

func (v *Viewer) applyXOffset() {
	if v.viewport == nil {
		return
	}
	v.viewport.SetXOffset(v.xOffset)
	v.xOffset = v.viewport.GetXOffsetWidth()
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
	v.rebuildObjectsForSelection()
	v.filter.SetBottomSticky(false)
	v.syncViewportSelection()
	v.updateOffset()
	return true
}

func (v *Viewer) HandleKey(msg tea.KeyPressMsg) tea.Cmd {
	v.ensureViewport()
	if v.filter == nil {
		return nil
	}
	startingSearch := msg.String() == "/"
	wasSearching := v.Searching()
	var cmd tea.Cmd
	v.filter, cmd = v.filter.Update(msg)
	switch {
	case msg.String() == "esc":
		v.searchActive = false
	case startingSearch:
		v.searchActive = true
	case wasSearching && msg.String() == "enter":
		v.searchActive = v.filter.GetFilterText() != ""
	}
	v.syncFromFilterSelection()
	return cmd
}

func (v Viewer) Searching() bool {
	return v.filter != nil && v.filter.FilterFocused()
}

func (v Viewer) FilterActive() bool {
	return v.searchActive
}

func (v *Viewer) ensureViewport() {
	if !v.wrapTextSet {
		v.wrapText = true
	}
	if v.width < 1 {
		v.width = 80
	}
	if v.height < 1 {
		v.height = 1
	}
	if v.viewport != nil {
		return
	}
	styles := v.styles()
	v.viewport = vpkg.New[viewerObject](
		v.width,
		v.viewportHeight(),
		vpkg.WithWrapText[viewerObject](v.wrapText),
		vpkg.WithSelectionEnabled[viewerObject](true),
		vpkg.WithFooterEnabled[viewerObject](false),
		vpkg.WithProgressBarEnabled[viewerObject](false),
		vpkg.WithSelectionStyleOverridesItemStyle[viewerObject](false),
		vpkg.WithStyles[viewerObject](styles),
	)
	v.filter = fvpkg.New[viewerObject](
		v.viewport,
		fvpkg.WithCanToggleMatchingItemsOnly[viewerObject](true),
		fvpkg.WithFilterModes[viewerObject]([]fvpkg.FilterMode{
			fvpkg.ExactFilterMode(key.NewBinding(key.WithKeys("/"), key.WithHelp("/", "search"))),
		}),
		fvpkg.WithItemDescriptor[viewerObject]("rows"),
	)
	v.filter.SetSelectionComparator(func(a, b viewerObject) bool {
		return a.key == b.key
	})

}

func (v Viewer) styles() vpkg.Styles {
	styles := vpkg.DefaultStyles()
	styles.SelectionPrefix = v.selectionPrefix
	styles.SelectedItemStyle = lipgloss.NewStyle().Background(cSelBg).Foreground(cWhite).Bold(true)
	return styles
}

func (v *Viewer) syncViewportSelection() {
	if v.filter == nil || len(v.objects) == 0 {
		return
	}
	v.filter.SetSelectedItemIdx(v.selectedObject)
	// Pass the full item width so expanded detail lines (body, etc.)
	// stay in viewport; passing width 1 only keeps the first cell visible.
	itemWidth := v.objects[v.selectedObject].item.Width()
	v.viewport.EnsureItemInView(v.selectedObject, 0, max(1, itemWidth), 0, 0)
}

func (v *Viewer) setObjects(objects []viewerObject) {
	v.filter.SetObjects(objects)
	if !v.searchActive && !v.Searching() {
		v.viewport.SetPreFooterLine("")
		v.viewport.SetObjects(objects)
	}
}

func (v *Viewer) rebuildObjectsForSelection() {
	if len(v.objects) == 0 {
		return
	}
	key := v.selectedKey
	v.objects = buildViewerObjects(v.lines, v.height, key)
	if idx, ok := v.objectIndexByKey(key); ok {
		v.selectedObject = idx
		v.cursor = v.objects[idx].lineIndex
	}
	v.setObjects(v.objects)
	v.applyXOffset()
}

func (v *Viewer) syncFromFilterSelection() {
	if v.filter == nil || len(v.objects) == 0 {
		return
	}
	selected := v.filter.GetSelectedItem()
	if selected == nil {
		return
	}
	if idx, ok := v.objectIndexByKey(selected.key); ok {
		v.selectedObject = idx
		v.cursor = v.objects[idx].lineIndex
		v.followBottom = idx == len(v.objects)-1
		v.updateSelectedKey()
		v.rebuildObjectsForSelection()
		itemWidth := v.objects[v.selectedObject].item.Width()
		v.viewport.EnsureItemInView(v.selectedObject, 0, max(1, itemWidth), 0, 0)
		v.updateOffset()
	}
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

func buildViewerObjects(lines []ViewerLine, height int, selectedKey string) []viewerObject {
	objects := make([]viewerObject, 0, len(lines))
	packUnselectable := height > 2
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
		if line.Key == selectedKey && packUnselectable {
			obj.lines = append(obj.lines, viewerLineDetail(line)...)
		}
		obj.item = viewerItem(obj.lines)
		objects = append(objects, obj)
	}
	return objects
}

func viewerLineDetail(line ViewerLine) []string {
	if line.DetailFunc != nil {
		return line.DetailFunc()
	}
	return line.Detail
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
