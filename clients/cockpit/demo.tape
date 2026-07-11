# Foreman Go cockpit showcase recording.
# Requires VHS (`brew install vhs`) and a working Go toolchain.
# Run from clients/cockpit with: vhs demo.tape

Output demo.gif
Set Shell "bash"
Set FontSize 14
Set Width 1280
Set Height 720
Set Theme "Dracula"

Type "COCKPIT_BACKEND=mock go run ."
Enter
Sleep 4s
Key "?"
Sleep 2s
Key "esc"
Sleep 1s
Key "tab"
Sleep 1s
Key "7"
Sleep 1s
Key "8"
Sleep 2s
Key "q"
