#Requires -Version 7.0

Set-StrictMode -Version Latest

$script:SupportedSteps = [ordered]@{
    basic_overhead = [ordered]@{
        label = '直斩'
        expected_tags = @('attack')
        expected_node_prefixes = @('atk.atk_101.')
        operations = @(
            [ordered]@{ kind = 'mouse_click'; button = 'left' }
        )
    }
    thrust = [ordered]@{
        label = '突刺'
        expected_tags = @('attack')
        expected_node_prefixes = @('atk.atk_104.')
        operations = @(
            [ordered]@{ kind = 'mouse_click'; button = 'right' }
        )
    }
    dodge = [ordered]@{
        label = '翻滚'
        expected_tags = @('escape')
        expected_node_prefixes = @('atk.esc_')
        operations = @(
            [ordered]@{ kind = 'key_click'; virtual_key = 0x20 }
        )
    }
    foresight_attempt = [ordered]@{
        label = '见切斩（尝试）'
        expected_tags = @('attack')
        expected_node_prefixes = @('atk.atk_147.atk_147')
        operations = @(
            [ordered]@{ kind = 'mouse_click'; button = 'left' }
            [ordered]@{
                kind = 'wait_for_action_signal'
                node_prefixes = @('atk.atk_101.')
                timeout_milliseconds = 1500
            }
            [ordered]@{ kind = 'mouse_chord'; first = 'x2'; second = 'right' }
        )
    }
    special_sheathe = [ordered]@{
        label = '特殊纳刀'
        expected_tags = @('attack')
        expected_node_prefixes = @('atk.atk151.atk_152')
        operations = @(
            [ordered]@{ kind = 'mouse_click'; button = 'left' }
            [ordered]@{
                kind = 'wait_for_action_signal'
                node_prefixes = @('atk.atk_101.')
                timeout_milliseconds = 1500
            }
            [ordered]@{ kind = 'mouse_key_chord'; button = 'x2'; virtual_key = 0x20 }
        )
    }
    iai_slash_attempt = [ordered]@{
        label = '居合拔刀斩（尝试）'
        expected_tags = @('attack')
        # atk_153 is a bounded community-data inference from the verified
        # atk_152 stance and atk_155 spirit route. Runtime evidence must confirm it.
        expected_node_prefixes = @('atk.atk151.atk_153')
        operations = @(
            [ordered]@{ kind = 'mouse_click'; button = 'left' }
            [ordered]@{
                kind = 'wait_for_action_signal'
                node_prefixes = @('atk.atk_101.')
                timeout_milliseconds = 1500
            }
            [ordered]@{ kind = 'mouse_key_chord'; button = 'x2'; virtual_key = 0x20 }
            [ordered]@{
                kind = 'wait_for_action_signal'
                node_prefixes = @('atk.atk151.atk_152')
                timeout_milliseconds = 2500
            }
            [ordered]@{ kind = 'mouse_click'; button = 'left' }
        )
    }
    iai_spirit_attempt = [ordered]@{
        label = '居合拔刀气刃斩（尝试）'
        expected_tags = @('attack')
        expected_node_prefixes = @('atk.atk151.atk_155')
        operations = @(
            [ordered]@{ kind = 'mouse_click'; button = 'left' }
            [ordered]@{
                kind = 'wait_for_action_signal'
                node_prefixes = @('atk.atk_101.')
                timeout_milliseconds = 1500
            }
            [ordered]@{ kind = 'mouse_key_chord'; button = 'x2'; virtual_key = 0x20 }
            [ordered]@{
                kind = 'wait_for_action_signal'
                node_prefixes = @('atk.atk151.atk_152')
                timeout_milliseconds = 2500
            }
            [ordered]@{ kind = 'mouse_click'; button = 'x2' }
        )
    }
}

function Get-LongSwordDefaultInputPlan {
    [CmdletBinding()]
    param([string[]]$Step = @())

    $ids = if ($Step.Count -eq 0) { @($script:SupportedSteps.Keys) } else { @($Step) }
    $result = foreach ($id in $ids) {
        if (-not $script:SupportedSteps.Contains($id)) {
            throw "Unsupported Long Sword input step '$id'. Supported: $($script:SupportedSteps.Keys -join ', ')"
        }
        $definition = $script:SupportedSteps[$id]
        [pscustomobject]@{
            id = $id
            label = $definition.label
            expected_tags = @($definition.expected_tags)
            expected_node_prefixes = @($definition.expected_node_prefixes)
            operations = @($definition.operations | ForEach-Object { [pscustomobject]$_ })
            source = 'capcom_official_windows_default_controls'
            source_url = 'https://game.capcom.com/manual/Multi-Platform/zh-hans/windows/page/3/6'
        }
    }
    return @($result)
}

function Initialize-MonsterCoachInputBridge {
    [CmdletBinding()]
    param()

    if ('MonsterCoachPlayerInputBridge' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class MonsterCoachPlayerInputBridge {
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr hWnd, int command);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);

    const uint KEYEVENTF_KEYUP = 0x0002;
    const uint KEYEVENTF_SCANCODE = 0x0008;
    const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004;
    const uint RIGHTDOWN = 0x0008, RIGHTUP = 0x0010;
    const uint XDOWN = 0x0080, XUP = 0x0100;

    public static bool AcquireFocus(IntPtr window) {
        if (window == IntPtr.Zero) return false;
        IntPtr foreground = GetForegroundWindow();
        if (foreground != window) {
            uint processId;
            uint foregroundThread = GetWindowThreadProcessId(foreground, out processId);
            uint currentThread = GetCurrentThreadId();
            bool attached = foregroundThread != 0 && AttachThreadInput(currentThread, foregroundThread, true);
            try {
                ShowWindowAsync(window, 9);
                BringWindowToTop(window);
                SetForegroundWindow(window);
                SetFocus(window);
            } finally {
                if (attached) AttachThreadInput(currentThread, foregroundThread, false);
            }
        }
        Thread.Sleep(foreground == window ? 10 : 250);
        return GetForegroundWindow() == window;
    }
    public static bool OwnsForeground(IntPtr window) {
        return window != IntPtr.Zero && GetForegroundWindow() == window;
    }
    static void MouseFlags(string button, out uint down, out uint up, out uint data) {
        data = 0;
        switch (button) {
            case "left": down = LEFTDOWN; up = LEFTUP; return;
            case "right": down = RIGHTDOWN; up = RIGHTUP; return;
            case "x1": down = XDOWN; up = XUP; data = 1; return;
            case "x2": down = XDOWN; up = XUP; data = 2; return;
            default: throw new ArgumentOutOfRangeException(nameof(button));
        }
    }
    public static bool KeyClick(IntPtr window, byte key) {
        if (!OwnsForeground(window)) return false;
        byte scan = (byte)MapVirtualKey(key, 0);
        if (scan == 0) return false;
        keybd_event(0, scan, KEYEVENTF_SCANCODE, UIntPtr.Zero);
        Thread.Sleep(120);
        keybd_event(0, scan, KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP, UIntPtr.Zero);
        return true;
    }
    public static bool MouseClick(IntPtr window, string button) {
        if (!OwnsForeground(window)) return false;
        uint down, up, data;
        MouseFlags(button, out down, out up, out data);
        mouse_event(down, 0, 0, data, UIntPtr.Zero);
        Thread.Sleep(120);
        mouse_event(up, 0, 0, data, UIntPtr.Zero);
        return true;
    }
    public static bool MouseChord(IntPtr window, string first, string second) {
        if (!OwnsForeground(window)) return false;
        uint firstDown, firstUp, firstData, secondDown, secondUp, secondData;
        MouseFlags(first, out firstDown, out firstUp, out firstData);
        MouseFlags(second, out secondDown, out secondUp, out secondData);
        mouse_event(firstDown, 0, 0, firstData, UIntPtr.Zero);
        mouse_event(secondDown, 0, 0, secondData, UIntPtr.Zero);
        Thread.Sleep(150);
        mouse_event(secondUp, 0, 0, secondData, UIntPtr.Zero);
        mouse_event(firstUp, 0, 0, firstData, UIntPtr.Zero);
        return true;
    }
    public static bool MouseKeyChord(IntPtr window, string button, byte key) {
        if (!OwnsForeground(window)) return false;
        byte scan = (byte)MapVirtualKey(key, 0);
        if (scan == 0) return false;
        uint down, up, data;
        MouseFlags(button, out down, out up, out data);
        mouse_event(down, 0, 0, data, UIntPtr.Zero);
        keybd_event(0, scan, KEYEVENTF_SCANCODE, UIntPtr.Zero);
        Thread.Sleep(150);
        keybd_event(0, scan, KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP, UIntPtr.Zero);
        mouse_event(up, 0, 0, data, UIntPtr.Zero);
        return true;
    }
    public static void ReleaseAllowlistedInputs() {
        byte scan = (byte)MapVirtualKey(0x20, 0);
        if (scan != 0) keybd_event(0, scan, KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP, UIntPtr.Zero);
        mouse_event(LEFTUP, 0, 0, 0, UIntPtr.Zero);
        mouse_event(RIGHTUP, 0, 0, 0, UIntPtr.Zero);
        mouse_event(XUP, 0, 0, 1, UIntPtr.Zero);
        mouse_event(XUP, 0, 0, 2, UIntPtr.Zero);
    }
}
'@
}

function Read-MonsterCoachActionSignal {
    param([Parameter(Mandatory)][string]$Path)
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        # The runtime replaces this small JSON document at an action boundary;
        # a poll can briefly overlap that write and should simply retry.
        return $null
    }
}

function Wait-MonsterCoachActionSignal {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Operation,
        [Parameter(Mandatory)][ref]$RevisionCursor
    )
    $prefixes = @($Operation.node_prefixes)
    $timeout = [int]($Operation.timeout_milliseconds ?? 1500)
    $deadline = (Get-Date).AddMilliseconds($timeout)
    do {
        $signal = Read-MonsterCoachActionSignal -Path $Path
        $revision = if ($signal) { [int]($signal.revision ?? 0) } else { 0 }
        $current = if ($signal) { $signal.current } else { $null }
        $nodeName = if ($current) { [string]($current.node_name ?? '') } else { '' }
        $matched = $revision -gt $RevisionCursor.Value -and $current `
            -and @($prefixes | Where-Object {
                $nodeName.StartsWith([string]$_)
            }).Count -gt 0
        if ($matched) {
            $RevisionCursor.Value = $revision
            return $true
        }
        Start-Sleep -Milliseconds 10
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Invoke-LongSwordInputStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IntPtr]$GameWindow,
        [Parameter(Mandatory)][string]$Step,
        [string]$ActionSignalPath
    )

    Initialize-MonsterCoachInputBridge
    $plan = Get-LongSwordDefaultInputPlan -Step $Step
    $initialSignal = if ([string]::IsNullOrWhiteSpace($ActionSignalPath)) {
        $null
    } else {
        Read-MonsterCoachActionSignal -Path $ActionSignalPath
    }
    $signalRevision = if ($initialSignal) { [int]($initialSignal.revision ?? 0) } else { 0 }
    try {
        foreach ($operation in $plan[0].operations) {
            $ok = $true
            switch ($operation.kind) {
                'delay' { Start-Sleep -Milliseconds ([int]$operation.milliseconds) }
                'wait_for_action_signal' {
                    if ([string]::IsNullOrWhiteSpace($ActionSignalPath)) {
                        throw "Step '$Step' requires a live action-signal path."
                    }
                    $ok = Wait-MonsterCoachActionSignal -Path $ActionSignalPath `
                        -Operation $operation -RevisionCursor ([ref]$signalRevision)
                }
                'key_click' {
                    $ok = [MonsterCoachPlayerInputBridge]::KeyClick(
                        $GameWindow, [byte]$operation.virtual_key)
                }
                'mouse_click' {
                    $ok = [MonsterCoachPlayerInputBridge]::MouseClick(
                        $GameWindow, [string]$operation.button)
                }
                'mouse_chord' {
                    $ok = [MonsterCoachPlayerInputBridge]::MouseChord(
                        $GameWindow, [string]$operation.first, [string]$operation.second)
                }
                'mouse_key_chord' {
                    $ok = [MonsterCoachPlayerInputBridge]::MouseKeyChord(
                        $GameWindow, [string]$operation.button, [byte]$operation.virtual_key)
                }
                default { throw "Unknown allowlisted input operation '$($operation.kind)'" }
            }
            if (-not $ok) {
                throw "Game focus was taken over by the player; calibration stopped before '$($operation.kind)' for '$Step'."
            }
        }
    } finally {
        [MonsterCoachPlayerInputBridge]::ReleaseAllowlistedInputs()
    }
}

Export-ModuleMember -Function Get-LongSwordDefaultInputPlan, Initialize-MonsterCoachInputBridge, `
    Invoke-LongSwordInputStep, Wait-MonsterCoachActionSignal
