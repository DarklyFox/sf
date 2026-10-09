# PGS Kiosk Manager 4.0 - Windows PowerShell 5.1 GUI
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'PGS-Engine.ps1')

if(-not (Test-PgsAdmin)) {
 # Relaunch elevated.
 Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs `
  -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
 exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$form=New-Object Windows.Forms.Form
$form.Text='PGS Kiosk Manager 4.0 - local user restrictions'
$form.StartPosition='CenterScreen'; $form.Size=New-Object Drawing.Size(940,870)
$form.Font=New-Object Drawing.Font('Segoe UI',9)

$label=New-Object Windows.Forms.Label
$label.Text='Select one or more standard local users (Ctrl/Shift for multiple). Selecting a single user loads their current settings. Administrators are never listed.'
$label.SetBounds(15,10,890,35); $form.Controls.Add($label)

$users=New-Object Windows.Forms.ListBox
$users.SelectionMode='MultiExtended'; $users.SetBounds(15,48,430,170); $form.Controls.Add($users)

$refresh=New-Object Windows.Forms.Button
$refresh.Text='Refresh accounts'; $refresh.SetBounds(460,48,210,32); $form.Controls.Add($refresh)
$reload=New-Object Windows.Forms.Button
$reload.Text='Reload selected user settings'; $reload.SetBounds(680,48,225,32); $form.Controls.Add($reload)

$info=New-Object Windows.Forms.Label
$info.Text="Checked = restriction ON, unchecked = OFF. 'Apply' makes the selected users match the checkboxes exactly. A backup of each user's previous settings is saved before every change.`r`n`r`nBest used while the user is signed out; for a signed-in user the changes apply after their next sign-in. These are per-user policies, not a locked-down single-app kiosk."
$info.SetBounds(460,90,445,128); $form.Controls.Add($info)

$group=New-Object Windows.Forms.GroupBox
$group.Text='Restrictions'; $group.SetBounds(15,228,890,330); $form.Controls.Add($group)
$checks=[ordered]@{}; $n=0
foreach($entry in $PgsFeatures.GetEnumerator()) {
 $ck=New-Object Windows.Forms.CheckBox
 $ck.Text=$entry.Value.Label; $ck.SetBounds(15,(24+$n*30),860,26)
 $group.Controls.Add($ck); $checks[$entry.Key]=$ck; $n++
}
$blockLabel=New-Object Windows.Forms.Label
$blockLabel.Text='Programs to block (file names, separated by commas):'
$blockLabel.SetBounds(15,(28+$n*30),860,20); $group.Controls.Add($blockLabel)
$blockBox=New-Object Windows.Forms.TextBox
$blockBox.Text=($PgsDefaultBlocked -join ', '); $blockBox.SetBounds(15,(50+$n*30),860,24); $group.Controls.Add($blockBox)

$apply=New-Object Windows.Forms.Button; $apply.Text='Apply to selected users'; $apply.SetBounds(15,568,215,36); $form.Controls.Add($apply)
$clear=New-Object Windows.Forms.Button; $clear.Text='Turn all restrictions off'; $clear.SetBounds(240,568,215,36); $form.Controls.Add($clear)
$restore=New-Object Windows.Forms.Button; $restore.Text='Restore from backup...'; $restore.SetBounds(465,568,215,36); $form.Controls.Add($restore)
$openDir=New-Object Windows.Forms.Button; $openDir.Text='Open backups folder'; $openDir.SetBounds(690,568,215,36); $form.Controls.Add($openDir)

$log=New-Object Windows.Forms.TextBox
$log.Multiline=$true; $log.ReadOnly=$true; $log.ScrollBars='Vertical'; $log.WordWrap=$true
$log.SetBounds(15,615,890,200); $form.Controls.Add($log)

function Append([string]$Message) {
 $log.AppendText(('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'),$Message.Trim())+"`r`n")
 $log.SelectionStart=$log.TextLength; $log.ScrollToCaret()
}

function Confirm-Pgs([string]$Text) {
 [Windows.Forms.MessageBox]::Show($Text,'Confirm',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning) -eq [Windows.Forms.DialogResult]::Yes
}

# Runs an engine call, showing its output, warnings and full error text in the log.
function Run-Pgs([scriptblock]$Operation) {
 $form.Cursor=[Windows.Forms.Cursors]::WaitCursor
 try { foreach($line in @(& $Operation 3>&1)){ Append "$line" } ; $true }
 catch { Append "ERROR: $($_.Exception.Message)"; $false }
 finally { $form.Cursor=[Windows.Forms.Cursors]::Default }
}

function LoadUsers {
 $users.Items.Clear(); $script:accounts=@()
 $script:accounts=@(Get-PgsUsers)
 foreach($a in $script:accounts) {
  $note=''
  if($a.SignedIn){$note='  (signed in)'}elseif(-not $a.HasProfile){$note='  (never signed in)'}
  [void]$users.Items.Add("$($a.Name)$note")
 }
 Append "Found $($script:accounts.Count) standard user(s)."
}

function SelectedNames {
 $names=@()
 foreach($i in @($users.SelectedIndices)){$names+=$script:accounts[[int]$i].Name}
 ,$names
}

function LoadSelectedState {
 $names=SelectedNames
 if($names.Count -ne 1){return}
 $form.Cursor=[Windows.Forms.Cursors]::WaitCursor
 try {
  $r=Invoke-PgsInspect $names[0]
  foreach($k in $checks.Keys){$checks[$k].Checked=[bool]$r.State[$k]}
  if(@($r.Blocked).Count){$blockBox.Text=(@($r.Blocked) -join ', ')}
  $active=@($r.State.Keys | Where-Object {$r.State[$_]})
  $summary='none'; if($active.Count){$summary=$active -join ', '}
  Append "$($r.Name): current restrictions: $summary"
 } catch { Append "ERROR: $($_.Exception.Message)" }
 finally { $form.Cursor=[Windows.Forms.Cursors]::Default }
}

$refresh.Add_Click({ try { LoadUsers } catch { Append "ERROR: $($_.Exception.Message)" } })
$reload.Add_Click({ if((SelectedNames).Count -ne 1){Append 'Select exactly one user.'}else{LoadSelectedState} })
$users.Add_SelectedIndexChanged({ LoadSelectedState })

$apply.Add_Click({
 $names=SelectedNames
 if($names.Count -eq 0){Append 'Select at least one user.'; return}
 $desired=@{}; foreach($k in $checks.Keys){$desired[$k]=$checks[$k].Checked}
 $blocked=Split-PgsList @($blockBox.Text)
 $on=@($checks.Keys | Where-Object {$desired[$_]})
 $summary='none (all restrictions off)'; if($on.Count){$summary=$on -join ', '}
 if(-not (Confirm-Pgs "Apply to: $($names -join ', ')`n`nRestrictions ON: $summary`n`nEverything else is turned OFF. A backup is saved first.")){return}
 foreach($name in $names){ [void](Run-Pgs { Invoke-PgsChange $name 'Apply' $desired $blocked }) }
})

$clear.Add_Click({
 $names=SelectedNames
 if($names.Count -eq 0){Append 'Select at least one user.'; return}
 if(-not (Confirm-Pgs "Turn OFF all restrictions managed by this tool for: $($names -join ', ')?`n`nA backup is saved first.")){return}
 foreach($name in $names){ [void](Run-Pgs { Invoke-PgsChange $name 'Clear' }) }
 if($names.Count -eq 1){LoadSelectedState}
})

$restore.Add_Click({
 $names=SelectedNames
 if($names.Count -ne 1){Append 'Select exactly one user to restore.'; return}
 Initialize-PgsStore
 $dialog=New-Object Windows.Forms.OpenFileDialog
 $dialog.Filter='PGS backup (*.json)|*.json'
 $userDir=Join-Path $PgsBackupDir $names[0]
 if(Test-Path -LiteralPath $userDir){$dialog.InitialDirectory=$userDir}else{$dialog.InitialDirectory=$PgsBackupDir}
 if($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){return}
 if(-not (Confirm-Pgs "Restore $($names[0]) from:`n$($dialog.FileName)`n`nThe current settings are backed up first.")){return}
 $file=$dialog.FileName
 if(Run-Pgs { Invoke-PgsChange $names[0] 'Restore' -BackupFile $file }){LoadSelectedState}
})

$openDir.Add_Click({ try { Initialize-PgsStore; Start-Process explorer.exe $PgsBackupDir } catch { Append "ERROR: $($_.Exception.Message)" } })

$form.Add_Shown({
 Append "Ready. Backups: $PgsBackupDir   Log: $PgsLogFile"
 try { LoadUsers } catch { Append "ERROR: Cannot list users: $($_.Exception.Message)" }
})
[void]$form.ShowDialog()
