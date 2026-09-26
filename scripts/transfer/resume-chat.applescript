-- Resume Chat: asks for a /transfer code, then runs resumework in a new Terminal window.
-- Built into "~/Desktop/Resume Chat.app" by install-transfer.sh (osacompile).
try
	set theCode to text returned of (display dialog "Enter the transfer code from your other Mac:" default answer "" with title "Resume Chat" buttons {"Cancel", "Resume"} default button "Resume" cancel button "Cancel")
on error
	return
end try
-- Keep only characters a code can contain, so nothing else ever reaches the shell.
set safeCode to do shell script "printf %s " & quoted form of theCode & " | tr -cd 'A-Za-z0-9-'"
if safeCode is "" then
	display dialog "That does not look like a transfer code." with title "Resume Chat" buttons {"OK"} default button "OK"
	return
end if
tell application "Terminal"
	activate
	do script "\"$HOME/.local/bin/resumework\" " & safeCode
end tell
