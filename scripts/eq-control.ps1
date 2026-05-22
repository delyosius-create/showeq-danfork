# EQ client control via SendInput scancodes + clipboard paste.
# DirectInput games ignore SendKeys/PostMessage; only hardware-level
# SendInput to the foreground window registers. Method (proven in the
# prior "EQ App"): clipboard the command, focus EQ, Enter (open chat),
# Ctrl+V (paste), Enter (send).
#
# Usage:
#   eq-control.ps1 -Mode send  -Cmd "/loc"     # send any slash command
#   eq-control.ps1 -Mode camp                  # /camp (-> char select)
#   eq-control.ps1 -Mode enter                 # Enter at char select (-> world)
#   eq-control.ps1 -Mode rezone                # camp, wait, re-enter (full session reset)
param(
  [ValidateSet('send','camp','enter','rezone')] [string]$Mode = 'send',
  [string]$Cmd = '',
  [int]$CampWaitSec = 35
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class EQInput {
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort vk; public ushort scan; public uint flags; public uint time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint data; public uint flags; public uint time; public IntPtr extra; }
  [StructLayout(LayoutKind.Explicit)]   public struct UNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public UNION u; }
  [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint n, INPUT[] p, int sz);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  const uint KB=1, KEYUP=2, SCAN=8;
  static int SZ = Marshal.SizeOf(typeof(INPUT));
  static void Send(INPUT[] i){ SendInput((uint)i.Length, i, SZ); }
  static INPUT K(ushort scan, bool up){ var i=new INPUT(); i.type=KB; i.u.ki.scan=scan; i.u.ki.flags=SCAN|(up?KEYUP:0); return i; }
  public static void ForceFocus(IntPtr hwnd){
    IntPtr fg=GetForegroundWindow(); uint fgT; GetWindowThreadProcessId(fg,out fgT);
    uint me=GetCurrentThreadId(); AttachThreadInput(me,fgT,true); SetForegroundWindow(hwnd); AttachThreadInput(me,fgT,false);
    int w=0; while(GetForegroundWindow()!=hwnd && w<2000){ Thread.Sleep(50); w+=50; }
  }
  public static void PressEnter(){ Send(new[]{K(0x1C,false)}); Thread.Sleep(60); Send(new[]{K(0x1C,true)}); }
  public static void CtrlV(){
    Send(new[]{K(0x1D,false)}); Thread.Sleep(80);
    Send(new[]{K(0x2F,false)}); Thread.Sleep(80);
    Send(new[]{K(0x2F,true)});  Thread.Sleep(80);
    Send(new[]{K(0x1D,true)});
  }
}
"@

$p = Get-Process eqgame -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { Write-Output "NOT_RUNNING"; exit 1 }
$h = $p.MainWindowHandle

function Send-EQCmd([string]$c) {
  Set-Clipboard -Value $c
  [EQInput]::ForceFocus($h); Start-Sleep -Milliseconds 350
  [EQInput]::PressEnter();   Start-Sleep -Milliseconds 400   # open chat line
  [EQInput]::CtrlV();        Start-Sleep -Milliseconds 250   # paste command
  [EQInput]::PressEnter()                                    # send
}

switch ($Mode) {
  'send'   { if (-not $Cmd) { Write-Output 'NO_CMD'; exit 1 }; Send-EQCmd $Cmd; Write-Output "SENT:$Cmd" }
  'camp'   { Send-EQCmd '/camp'; Write-Output 'CAMPING' }
  'enter'  { [EQInput]::ForceFocus($h); Start-Sleep -Milliseconds 400; [EQInput]::PressEnter(); Write-Output 'ENTER' }
  'rezone' {
    Send-EQCmd '/camp'; Write-Output 'CAMPING'
    Start-Sleep -Seconds $CampWaitSec
    [EQInput]::ForceFocus($h); Start-Sleep -Milliseconds 600
    [EQInput]::PressEnter(); Start-Sleep -Milliseconds 500   # enter world at char select
    Write-Output 'REZONED'
  }
}
