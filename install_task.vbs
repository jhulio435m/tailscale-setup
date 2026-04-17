Set WshShell = CreateObject("WScript.Shell")
Set ShellApp = CreateObject("Shell.Application")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptPath = fso.GetParentFolderName(WScript.ScriptFullName) & "\create-task.ps1"
command = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """ -Clean"

adminCheck = WshShell.Run("cmd.exe /c net session >nul 2>&1", 0, True)

If adminCheck = 0 Then
    WshShell.Run "powershell.exe " & command, 0, False
Else
    ShellApp.ShellExecute "powershell.exe", command, "", "runas", 0
End If
