# Foreman Go cockpit showcase recording.
# Requires VHS, ttyd, and a working Go toolchain (`brew install vhs ttyd`).
# Run from clients/cockpit with: vhs demo.tape

Output demo.gif
Set Shell "bash"
Set FontSize 14
Set Width 1280
Set Height 720
Set Theme "Dracula"

Type "COCKPIT_BACKEND=mock COCKPIT_DEMO=1 go run ."
Enter
Sleep 4s
Type "?"
Sleep 2s
Escape
Sleep 1s
Tab
Sleep 1s
Type "7"
Sleep 1s
Type "8"
Sleep 2s
Type "q"
