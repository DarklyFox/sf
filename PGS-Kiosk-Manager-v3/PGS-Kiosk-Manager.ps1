# PGS Kiosk Manager 3.0 Windows PowerShell 5.1 GUI
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$engine=Join-Path $PSScriptRoot 'PGS-Engine.ps1'
$root=Join-Path $env:ProgramData 'PGS-Kiosk-Manager'
$form=New-Object Windows.Forms.Form
$form.Text='PGS Kiosk Manager 3.0 - Local Windows 11 accounts'
$form.StartPosition='CenterScreen';$form.Size=New-Object Drawing.Size(900,825)
$form.Font=New-Object Drawing.Font('Segoe UI',9)
$label=New-Object Windows.Forms.Label;$label.Text='Select local standard users (Ctrl/Shift for multiple). Users MUST be signed out. Administrator accounts are excluded.';$label.SetBounds(15,12,850,35);$form.Controls.Add($label)
$users=New-Object Windows.Forms.ListBox;$users.SelectionMode='MultiExtended';$users.SetBounds(15,50,420,178);$form.Controls.Add($users)
$refresh=New-Object Windows.Forms.Button;$refresh.Text='Refresh accounts';$refresh.SetBounds(450,50,180,34);$form.Controls.Add($refresh)
$info=New-Object Windows.Forms.Label;$info.Text='Applies registry-based controls per user. NOT a secure single-app kiosk. Local Group Policy may override registry changes. Microsoft Store AppLocker enforcement is not automated.';$info.SetBounds(450,95,420,125);$form.Controls.Add($info)
$group=New-Object Windows.Forms.GroupBox;$group.Text='Restriction switches (checked = restricted)';$group.SetBounds(15,240,855,257);$form.Controls.Add($group)
$opts=[ordered]@{
 HideDrives='Hide drive icons, preserve personal folder access'
 TaskManager='Disable Task Manager'
 CommandPrompt='Block command prompt (batch scripts still run)'
 Settings='Block Settings and Control Panel'
 RunMenu='Remove Run from Start menu'
 ShellBlock='Block PowerShell, Terminal, Registry Editor, MMC via Explorer (best effort)'
}
$checks=@{};$n=0
foreach($o in $opts.GetEnumerator()){
 $ck=New-Object Windows.Forms.CheckBox;$ck.Text=$o.Value;$ck.SetBounds(15,(25+$n*35),815,30);$ck.Checked=$true
 $group.Controls.Add($ck);$checks[$o.Key]=$ck;$n++
}
$actions=@(@('Inspect one user',15),@('Apply checked settings',185),@('Clear PGS controls',355),@('Restore v3 backup',525))
$log=New-Object Windows.Forms.TextBox;$log.Multiline=$true;$log.ReadOnly=$true;$log.ScrollBars='Both';$log.WordWrap=$false;$log.SetBounds(15,557,855,155);$form.Controls.Add($log)
function Append([string]$message){$log.AppendText("`r`n"+$message);$log.SelectionStart=$log.TextLength;$log.ScrollToCaret()}
function LoadUsers {
 $users.Items.Clear()
 $script:accounts=@()
 $out=@(& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $engine -Action Users 2>&1)
 $text=(@($out|Where-Object {$_ -isnot [Management.Automation.ErrorRecord]})|Out-String).Trim()
 $errors=(@($out|Where-Object {$_ -is [Management.Automation.ErrorRecord]})|Out-String).Trim()
 if($LASTEXITCODE -ne 0 -or -not $text){throw "Could not list accounts. $errors $text"}
 $script:accounts=@(ConvertFrom-Json $text)
 foreach($a in $script:accounts){[void]$users.Items.Add("$($a.Name)  [$($a.SID)]")}
}
$refresh.Add_Click({try{LoadUsers}catch{[Windows.Forms.MessageBox]::Show("$_")}})
function InvokeEngine([string]$act,[string[]]$names,[string]$enable='', [string]$backup=''){
 $argsList=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$engine,'-Action',$act,'-UserName',($names -join '|'))
 if($act -in @('Apply','Clear','Restore')){$argsList+= '-Confirm'}
 if($act -eq 'Apply' -and $enable){$argsList+=@('-Enable',$enable)}
 if($backup){$argsList+=@('-BackupFile',$backup)}
 # Execute engine in a child PS process so no PowerShell registry-provider handles are retained.
 # Native stderr must not become a terminating error in this script.
 $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
 try{$output=& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @argsList 2>&1}finally{$ErrorActionPreference=$previous}
 Append (($output|ForEach-Object {"$_"})|Out-String)
}
function SelectedNames {
 $names=@()
 foreach($i in @($users.SelectedIndices)){$names+= $script:accounts[[int]$i].Name}
 return ,$names
}
foreach($entry in $actions){
 $b=New-Object Windows.Forms.Button;$b.Text=$entry[0];$b.SetBounds([int]$entry[1],510,160,35);$form.Controls.Add($b)
 switch($entry[0]){
 'Inspect one user' { $b.Add_Click({try{$names=SelectedNames;if($names.Count -ne 1){throw 'Select exactly one user.'};InvokeEngine 'Inspect' $names}catch{Append "ERROR: $_"}}) }
 'Apply checked settings' {$b.Add_Click({try{$names=SelectedNames;if($names.Count -eq 0){throw 'Select users.'};$d=@(foreach($k in $checks.Keys){if($checks[$k].Checked){$k}});if([Windows.Forms.MessageBox]::Show("Apply to $($names -join ', ')? Each user gets a backup.",'Confirm',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning) -ne [Windows.Forms.DialogResult]::Yes){return};InvokeEngine 'Apply' $names ($d -join ',')}catch{Append "ERROR: $_"}})}
 'Clear PGS controls' {$b.Add_Click({try{$names=SelectedNames;if($names.Count -eq 0){throw 'Select users.'};if([Windows.Forms.MessageBox]::Show("CLEAR the PGS-managed restrictions for $($names -join ', ')? This relaxes kiosk restrictions.",'Confirm',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning) -ne [Windows.Forms.DialogResult]::Yes){return};InvokeEngine 'Clear' $names}catch{Append "ERROR: $_"}})}
 'Restore v3 backup' {$b.Add_Click({try{$names=SelectedNames;if($names.Count -ne 1){throw 'Select one user.'};$dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='PGS v3 JSON (*.json)|*.json';$dialog.InitialDirectory=Join-Path $root 'Backups';if($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){return};if([Windows.Forms.MessageBox]::Show('Restore selected v3 backup? A new pre-restore backup will be created.','Confirm',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning) -ne [Windows.Forms.DialogResult]::Yes){return};InvokeEngine 'Restore' $names '' $dialog.FileName}catch{Append "ERROR: $_"}})}
 }
}
$store=New-Object Windows.Forms.Button;$store.Text='Store/AppLocker status';$store.SetBounds(15,720,200,28);$form.Controls.Add($store)
$store.Add_Click({try{$service=Get-Service AppIDSvc -ErrorAction SilentlyContinue; $xml=Get-AppLockerPolicy -Effective -Xml -ErrorAction Stop;Append "AppIDSvc: $($service.Status). AppLocker effective policy XML length: $($xml.Length). Store enforcement is not configured by this tool."}catch{Append "AppLocker check: $_"}})
try{LoadUsers;Append 'Ready. Pilot build. Backups: C:\ProgramData\PGS-Kiosk-Manager\Backups'}catch{Append "Cannot enumerate users: $_"}
[void]$form.ShowDialog()
