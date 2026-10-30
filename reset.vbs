' Reset the desk pet: restart it right next to the mouse cursor.
' Use this when you cannot find the pet on screen.
Option Explicit
Dim fso, sh, base
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
base = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = base
sh.Run "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & base & "\DeskPet.ps1"" -AtCursor", 0, False