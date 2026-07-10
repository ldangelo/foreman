package main

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

// Viewer owns cursor and scroll state for drill-down tabs.
type Viewer struct {
	lines        []ViewerLine
	cursor       int
	offset       int
	selectedKey  string
	followBottom bool
}

func (v *Viewer) SetLines(lines []ViewerLine, policy viewerRefreshPolicy, height int) {
	v.lines = lines
	if len(lines) == 0 {
		v.cursor = 0
		v.offset = 0
		v.selectedKey = ""
		v.followBottom = false
		return
	}

	switch policy {
	case viewerReset:
		v.cursor = v.firstSelectableIndex()
		v.followBottom = false
	case viewerBottom:
		v.cursor = v.lastSelectableIndex()
		v.followBottom = true
	default:
		if v.followBottom {
			v.cursor = v.lastSelectableIndex()
		} else if !v.selectKey(v.selectedKey) {
			v.clampCursor()
		}
		v.followBottom = v.cursor == v.lastSelectableIndex()
	}
	v.updateSelectedKey()
	v.keepCursorVisible(height)
}

func (v *Viewer) Move(delta, height int) {
	if len(v.lines) == 0 {
		v.cursor = 0
		v.offset = 0
		v.selectedKey = ""
		v.followBottom = false
		return
	}
	v.moveCursor(delta)
	v.clampCursor()
	v.followBottom = v.cursor == v.lastSelectableIndex()
	v.updateSelectedKey()
	v.keepCursorVisible(height)
}

func (v *Viewer) Reset(height int) {
	v.cursor = 0
	v.offset = 0
	v.followBottom = false
	v.updateSelectedKey()
	v.keepCursorVisible(height)
}

func (v Viewer) TextLines() []string {
	out := make([]string, len(v.lines))
	for i, line := range v.lines {
		out[i] = line.Text
	}
	return out
}

func (v Viewer) SelectedLine() (ViewerLine, bool) {
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

func (v *Viewer) selectKey(key string) bool {
	if key == "" {
		return false
	}
	for i, line := range v.lines {
		if line.Key == key && v.isSelectableIndex(i) {
			v.cursor = i
			return true
		}
	}
	return false
}
func (v *Viewer) SelectKey(key string, height int) bool {
	if !v.selectKey(key) {
		return false
	}
	v.followBottom = v.cursor == v.lastSelectableIndex()
	v.updateSelectedKey()
	v.keepCursorVisible(height)
	return true
}

func (v Viewer) isSelectableIndex(i int) bool {
	return i >= 0 && i < len(v.lines) && !v.lines[i].Unselectable
}

func (v Viewer) firstSelectableIndex() int {
	for i := range v.lines {
		if v.isSelectableIndex(i) {
			return i
		}
	}
	return 0
}

func (v Viewer) lastSelectableIndex() int {
	for i := len(v.lines) - 1; i >= 0; i-- {
		if v.isSelectableIndex(i) {
			return i
		}
	}
	return 0
}

func (v *Viewer) moveCursor(delta int) {
	if delta == 0 || len(v.lines) == 0 {
		return
	}
	step := 1
	if delta < 0 {
		step = -1
		delta = -delta
	}
	if !v.isSelectableIndex(v.cursor) {
		v.clampCursor()
	}
	for ; delta > 0; delta-- {
		next := v.cursor + step
		for next >= 0 && next < len(v.lines) && !v.isSelectableIndex(next) {
			next += step
		}
		if next < 0 || next >= len(v.lines) {
			return
		}
		v.cursor = next
	}
}

func (v *Viewer) clampCursor() {
	if len(v.lines) == 0 {
		v.cursor = 0
		v.offset = 0
		return
	}
	if v.cursor < 0 {
		v.cursor = 0
	}
	if v.cursor >= len(v.lines) {
		v.cursor = v.lastSelectableIndex()
	}
	if !v.isSelectableIndex(v.cursor) {
		for i := v.cursor; i >= 0; i-- {
			if v.isSelectableIndex(i) {
				v.cursor = i
				return
			}
		}
		v.cursor = v.firstSelectableIndex()
	}
}

func (v *Viewer) keepCursorVisible(height int) {
	h := viewerHeight(height)
	maxOffset := v.MaxScroll(h)
	visibleEnd := v.cursor
	if v.isSelectableIndex(v.cursor) && v.lines[v.cursor].KeepNext && v.cursor+1 < len(v.lines) {
		visibleEnd = v.cursor + 1
	}
	if visibleEnd >= len(v.lines) {
		visibleEnd = len(v.lines) - 1
	}
	if visibleEnd < v.cursor {
		visibleEnd = v.cursor
	}
	blockHeight := visibleEnd - v.cursor + 1
	v.offset = v.cursor - (h-blockHeight)/2
	if v.offset < 0 {
		v.offset = 0
	}
	if v.offset > maxOffset {
		v.offset = maxOffset
	}
}

func (v *Viewer) updateSelectedKey() {
	if line, ok := v.SelectedLine(); ok {
		v.selectedKey = line.Key
	} else {
		v.selectedKey = ""
	}
}

func viewerHeight(height int) int {
	if height < 1 {
		return 1
	}
	return height
}
