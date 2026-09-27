# Render with: vhs docs/tapes/demo.tape (from the repository root)
Output docs/images/demo.gif
Set Shell "bash"
Set FontSize 16
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms
Set Width 1300
Set Height 420
Env BASH_SILENCE_DEPRECATION_WARNING "1"

Hide
Type 'export PS1="\[\e[1;35m\]org-patch-manager\[\e[0m\] $ "; clear' Enter
Sleep 500ms
Show
Type "make demo" Sleep 400ms Enter
Wait+Screen@120s /us-west-2 +all instances/
Sleep 6s
