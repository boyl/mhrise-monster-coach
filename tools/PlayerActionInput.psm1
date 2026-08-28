#Requires -Version 7.0

Set-StrictMode -Version Latest

$script:SupportedSteps = [ordered]@{
    basic_overhead = [ordered]@{
        label = '直斩'
        expected_tags = @('attack')
        expected_node_prefixes = @('atk.atk_101.')
        operations = @(
            [ordered]@{ kind = 'mouse_click'; button = 'left'; role = 'primary_attack' }
        )
    }
    thrust = [ordered]@{
        label = '突刺'
        expected_tags = @('attack')
        expected_node_prefixes = @('atk.atk_104.')
        operations = @(
            [ordered]@{ kind = 'mouse_click'; button = 'right'; role = 'secondary_attack' }
        )
    }
    dodge = [ordered]@{
        label = '翻滚'
        expected_tags = @('escape')
        expected_node_prefixes = @('atk.esc_')
        operations = @(
            [ordered]@{ kind = 'key_click'; virtual_key = 0x20; role = 'evade' }
        )
    }
    foresight_attempt = [ordered]@{
        label = '见切斩（尝试）'
        expected_tags = @('attack')
        expected_node_prefixes = @('atk.atk_147.atk_147')
        operations = @(
            [ordered]@{ kind = 'mouse_click'; button = 'left'; role = 'primary_attack' }
            [ordered]@{
                kind = 'wait_for_action_signal'
                node_prefixes = @('atk.atk_101.')
                timeout_milliseconds = 1500
            }
            # Capcom's default "Mouse Button 4" is Win32 XBUTTON1 (dwData 0x0001).
            [ordered]@{
                kind = 'mouse_chord'; first = 'x1'; second = 'right'
                roles = @('weapon_special', 'secondary_attack')
            }
        )
    }
    special_sheathe = [ordered]@{
        label = '特殊纳刀'
        required_switch_skill = 'special_sheathe_combo'
        expected_tags = @('attack')
        expected_node_prefixes = @('atk.atk151.atk_152')
        operations = @(
            [ordered]@{ kind = 'mouse_click'; button = 'left'; role = 'primary_attack' }
            [ordered]@{
                kind = 'wait_for_action_signal'
                node_prefixes = @('atk.atk_101.')
                timeout_milliseconds = 1500
            }
            [ordered]@{
                kind = 'mouse_key_chord'; button = 'x1'; virtual_key = 0x20
                roles = @('weapon_special', 'evade')
            }
        )
    }
    iai_slash_attempt = [ordered]@{
        label = '居合拔刀斩（尝试）'
        required_switch_skill = 'special_sheathe_combo'
        expected_tags = @('attack')
        # atk_153 is a bounded community-data inference from the verified
        # atk_152 stance and atk_155 spirit route. Runtime evidence must confirm it.
        expected_node_prefixes = @('atk.atk151.atk_153')
        operations = @(
            [ordered]@{ kind = 'mouse_click'; button = 'left'; role = 'primary_attack' }
            [ordered]@{
                kind = 'wait_for_action_signal'
                node_prefixes = @('atk.atk_101.')
                timeout_milliseconds = 1500
            }
            [ordered]@{
                kind = 'mouse_key_chord'; button = 'x1'; virtual_key = 0x20
                roles = @('weapon_special', 'evade')
            }
            [ordered]@{
                kind = 'wait_for_action_signal'
                node_prefixes = @('atk.atk151.atk_152')
                timeout_milliseconds = 2500
            }
            [ordered]@{ kind = 'mouse_click'; button = 'left'; role = 'primary_attack' }
        )
    }
    iai_spirit_attempt = [ordered]@{
        label = '居合拔刀气刃斩（尝试）'
        required_switch_skill = 'special_sheathe_combo'
        expected_tags = @('attack')
        expected_node_prefixes = @('atk.atk151.atk_155')
        operations = @(
            [ordered]@{ kind = 'mouse_click'; button = 'left'; role = 'primary_attack' }
            [ordered]@{
                kind = 'wait_for_action_signal'
                node_prefixes = @('atk.atk_101.')
                timeout_milliseconds = 1500
            }
            [ordered]@{
                kind = 'mouse_key_chord'; button = 'x1'; virtual_key = 0x20
                roles = @('weapon_special', 'evade')
            }
            [ordered]@{
                kind = 'wait_for_action_signal'
                node_prefixes = @('atk.atk151.atk_152')
                timeout_milliseconds = 2500
            }
            [ordered]@{ kind = 'mouse_click'; button = 'x1'; role = 'weapon_special' }
        )
    }
}

function Get-LongSwordDefaultInputPlan {
    [CmdletBinding()]
    param(
        [string[]]$Step = @(),
        [string[]]$ActiveSwitchSkill = @()
    )

    $ids = if ($Step.Count -eq 0) { @($script:SupportedSteps.Keys) } else { @($Step) }
    $availabilityKnown = $PSBoundParameters.ContainsKey('ActiveSwitchSkill')
    $result = foreach ($id in $ids) {
        if (-not $script:SupportedSteps.Contains($id)) {
            throw "Unsupported Long Sword input step '$id'. Supported: $($script:SupportedSteps.Keys -join ', ')"
        }
        $definition = $script:SupportedSteps[$id]
        $requiredSwitchSkill = if ($definition.Contains('required_switch_skill')) {
            [string]$definition.required_switch_skill
        } else { $null }
        $applicable = -not $availabilityKnown -or [string]::IsNullOrWhiteSpace($requiredSwitchSkill) `
            -or $requiredSwitchSkill -in $ActiveSwitchSkill
        [pscustomobject]@{
            id = $id
            label = $definition.label
            required_switch_skill = $requiredSwitchSkill
            applicable = $applicable
            inapplicable_reason = if ($applicable) { $null } else {
                "Active switch-skill loadout does not contain '$requiredSwitchSkill'."
            }
            expected_tags = @($definition.expected_tags)
            expected_node_prefixes = @($definition.expected_node_prefixes)
            operations = @($definition.operations | ForEach-Object { [pscustomobject]$_ })
            source = 'capcom_official_windows_default_controls'
            source_url = 'https://game.capcom.com/manual/Multi-Platform/zh-hans/windows/page/3/6'
            win32_xbutton_source_url = 'https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-mouse_event'
        }
    }
    return @($result)
}

function ConvertTo-MonsterCoachPhysicalBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Binding,
        [Parameter(Mandatory)][string]$Role
    )

    if ([string]$Binding.status -ne 'resolved') {
        throw "Input role '$Role' is unavailable: $([string]$Binding.status)"
    }
    $name = [string]$Binding.name
    switch ($name) {
        'MOUSE_L' { return [pscustomobject]@{ device = 'mouse'; button = 'left'; source_name = $name } }
        'MOUSE_R' { return [pscustomobject]@{ device = 'mouse'; button = 'right'; source_name = $name } }
        'MOUSE_EX1' { return [pscustomobject]@{ device = 'mouse'; button = 'x1'; source_name = $name } }
        'MOUSE_EX2' { return [pscustomobject]@{ device = 'mouse'; button = 'x2'; source_name = $name } }
        'Space' {
            return [pscustomobject]@{
                device = 'keyboard'; virtual_key = [byte]0x20; source_name = $name
            }
        }
        'None' { throw "Input role '$Role' has no keyboard or mouse binding." }
        default {
            throw "Input role '$Role' uses unsupported keyboard/mouse binding '$name'."
        }
    }
}

function Resolve-MonsterCoachInputBindings {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$BindingContract)

    if ([string]$BindingContract.policy -ne 'read_only_exact_dictionary_lookup') {
        throw "Unsupported binding contract policy '$([string]$BindingContract.policy)'."
    }
    if ([int]($BindingContract.call_failures ?? 0) -ne 0 `
        -or [int]($BindingContract.value_failures ?? 0) -ne 0 `
        -or $BindingContract.truncated -eq $true) {
        throw 'Current binding contract is incomplete or contains runtime lookup failures.'
    }

    $resolved = [ordered]@{}
    foreach ($target in @($BindingContract.targets)) {
        $role = [string]$target.role
        if ([string]::IsNullOrWhiteSpace($role)) { continue }
        $candidate = $target.main
        if ($null -eq $candidate -or [string]$candidate.status -ne 'resolved' `
            -or [string]$candidate.name -eq 'None') {
            $candidate = $target.sub
        }
        $resolved[$role] = ConvertTo-MonsterCoachPhysicalBinding `
            -Binding $candidate -Role $role
    }

    foreach ($required in @('evade', 'primary_attack', 'secondary_attack', 'weapon_special')) {
        if (-not $resolved.Contains($required)) {
            throw "Current binding contract does not contain required role '$required'."
        }
    }
    return [pscustomobject]$resolved
}

function ConvertTo-MonsterCoachResolvedOperation {
    param(
        [Parameter(Mandatory)]$Operation,
        [Parameter(Mandatory)]$Bindings
    )

    $roleProperty = $Operation.PSObject.Properties['role']
    $rolesProperty = $Operation.PSObject.Properties['roles']
    if ($null -eq $roleProperty -and $null -eq $rolesProperty) {
        $copy = [ordered]@{}
        foreach ($property in $Operation.PSObject.Properties) {
            $copy[$property.Name] = $property.Value
        }
        return [pscustomobject]$copy
    }

    if ($null -ne $roleProperty) {
        $role = [string]$roleProperty.Value
        $binding = $Bindings.$role
        if ($null -eq $binding) { throw "Resolved input role '$role' is missing." }
        if ($binding.device -eq 'mouse') {
            return [pscustomobject][ordered]@{
                kind = 'mouse_click'; button = $binding.button; role = $role
                binding_name = $binding.source_name
            }
        }
        if ($binding.device -eq 'keyboard') {
            return [pscustomobject][ordered]@{
                kind = 'key_click'; virtual_key = $binding.virtual_key; role = $role
                binding_name = $binding.source_name
            }
        }
        throw "Resolved input role '$role' uses unsupported device '$($binding.device)'."
    }

    $roles = @($rolesProperty.Value)
    if ($roles.Count -ne 2) { throw 'A semantic input chord must contain exactly two roles.' }
    $firstRole = [string]$roles[0]
    $secondRole = [string]$roles[1]
    $first = $Bindings.$firstRole
    $second = $Bindings.$secondRole
    if ($null -eq $first -or $null -eq $second) {
        throw "Resolved input chord '$($roles -join '+')' is incomplete."
    }
    if ($first.device -eq 'mouse' -and $second.device -eq 'mouse') {
        return [pscustomobject][ordered]@{
            kind = 'mouse_chord'; first = $first.button; second = $second.button
            roles = $roles; binding_names = @($first.source_name, $second.source_name)
        }
    }
    $mouse = if ($first.device -eq 'mouse') { $first }
        elseif ($second.device -eq 'mouse') { $second } else { $null }
    $keyboard = if ($first.device -eq 'keyboard') { $first }
        elseif ($second.device -eq 'keyboard') { $second } else { $null }
    if ($mouse -and $keyboard) {
        return [pscustomobject][ordered]@{
            kind = 'mouse_key_chord'; button = $mouse.button
            virtual_key = $keyboard.virtual_key; roles = $roles
            binding_names = @($first.source_name, $second.source_name)
        }
    }
    throw "Resolved input chord '$($roles -join '+')' has no allowlisted bridge implementation."
}

function Get-LongSwordCurrentInputPlan {
    [CmdletBinding()]
    param(
        [string[]]$Step = @(),
        [string[]]$ActiveSwitchSkill = @(),
        [Parameter(Mandatory)]$BindingContract
    )

    $bindings = Resolve-MonsterCoachInputBindings -BindingContract $BindingContract
    $parameters = @{ Step = $Step }
    if ($PSBoundParameters.ContainsKey('ActiveSwitchSkill')) {
        $parameters.ActiveSwitchSkill = $ActiveSwitchSkill
    }
    $defaults = @(Get-LongSwordDefaultInputPlan @parameters)
    return @($defaults | ForEach-Object {
        [pscustomobject][ordered]@{
            id = $_.id
            label = $_.label
            required_switch_skill = $_.required_switch_skill
            applicable = $_.applicable
            inapplicable_reason = $_.inapplicable_reason
            expected_tags = @($_.expected_tags)
            expected_node_prefixes = @($_.expected_node_prefixes)
            operations = @($_.operations | ForEach-Object {
                ConvertTo-MonsterCoachResolvedOperation -Operation $_ -Bindings $bindings
            })
            source = 'runtime_stm_input_config'
            source_policy = [string]$BindingContract.policy
            resolved_bindings = $bindings
        }
    })
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
    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint count, INPUT[] inputs, int size);

    [StructLayout(LayoutKind.Sequential)]
    struct INPUT {
        public uint type;
        public INPUTUNION value;
    }
    [StructLayout(LayoutKind.Explicit)]
    struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mouse;
        [FieldOffset(0)] public KEYBDINPUT keyboard;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint flags;
        public uint time;
        public UIntPtr extraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT {
        public ushort virtualKey;
        public ushort scanCode;
        public uint flags;
        public uint time;
        public UIntPtr extraInfo;
    }

    const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
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
    static INPUT MouseInput(uint flags, uint data) {
        return new INPUT {
            type = INPUT_MOUSE,
            value = new INPUTUNION {
                mouse = new MOUSEINPUT { flags = flags, mouseData = data }
            }
        };
    }
    static INPUT KeyInput(byte scan, bool up) {
        return new INPUT {
            type = INPUT_KEYBOARD,
            value = new INPUTUNION {
                keyboard = new KEYBDINPUT {
                    scanCode = scan,
                    flags = KEYEVENTF_SCANCODE | (up ? KEYEVENTF_KEYUP : 0)
                }
            }
        };
    }
    static bool Send(params INPUT[] inputs) {
        return inputs.Length > 0 && SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>())
            == (uint)inputs.Length;
    }
    public static bool KeyClick(IntPtr window, byte key) {
        if (!OwnsForeground(window)) return false;
        byte scan = (byte)MapVirtualKey(key, 0);
        if (scan == 0) return false;
        if (!Send(KeyInput(scan, false))) return false;
        Thread.Sleep(120);
        return Send(KeyInput(scan, true));
    }
    public static bool MouseClick(IntPtr window, string button) {
        if (!OwnsForeground(window)) return false;
        uint down, up, data;
        MouseFlags(button, out down, out up, out data);
        if (!Send(MouseInput(down, data))) return false;
        Thread.Sleep(120);
        return Send(MouseInput(up, data));
    }
    public static bool MouseChord(IntPtr window, string first, string second) {
        if (!OwnsForeground(window)) return false;
        uint firstDown, firstUp, firstData, secondDown, secondUp, secondData;
        MouseFlags(first, out firstDown, out firstUp, out firstData);
        MouseFlags(second, out secondDown, out secondUp, out secondData);
        if (!Send(MouseInput(firstDown, firstData), MouseInput(secondDown, secondData))) return false;
        Thread.Sleep(150);
        return Send(MouseInput(secondUp, secondData), MouseInput(firstUp, firstData));
    }
    public static bool MouseKeyChord(IntPtr window, string button, byte key) {
        if (!OwnsForeground(window)) return false;
        byte scan = (byte)MapVirtualKey(key, 0);
        if (scan == 0) return false;
        uint down, up, data;
        MouseFlags(button, out down, out up, out data);
        if (!Send(MouseInput(down, data), KeyInput(scan, false))) return false;
        Thread.Sleep(150);
        return Send(KeyInput(scan, true), MouseInput(up, data));
    }
    public static void ReleaseAllowlistedInputs() {
        byte scan = (byte)MapVirtualKey(0x20, 0);
        var releases = new System.Collections.Generic.List<INPUT>();
        if (scan != 0) releases.Add(KeyInput(scan, true));
        releases.Add(MouseInput(LEFTUP, 0));
        releases.Add(MouseInput(RIGHTUP, 0));
        releases.Add(MouseInput(XUP, 1));
        releases.Add(MouseInput(XUP, 2));
        Send(releases.ToArray());
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
        [string]$Step = '',
        $Definition,
        [string]$ActionSignalPath
    )

    Initialize-MonsterCoachInputBridge
    if ($null -eq $Definition) {
        if ([string]::IsNullOrWhiteSpace($Step)) {
            throw 'Invoke-LongSwordInputStep requires Step or a resolved Definition.'
        }
        $Definition = @(Get-LongSwordDefaultInputPlan -Step $Step)[0]
    }
    $stepId = [string]$Definition.id
    $initialSignal = if ([string]::IsNullOrWhiteSpace($ActionSignalPath)) {
        $null
    } else {
        Read-MonsterCoachActionSignal -Path $ActionSignalPath
    }
    $signalRevision = if ($initialSignal) { [int]($initialSignal.revision ?? 0) } else { 0 }
    try {
        foreach ($operation in @($Definition.operations)) {
            if (-not [MonsterCoachPlayerInputBridge]::OwnsForeground($GameWindow)) {
                throw [System.OperationCanceledException]::new(
                    "Player took over game focus before '$($operation.kind)' for '$stepId'.")
            }
            $ok = $true
            switch ($operation.kind) {
                'delay' { Start-Sleep -Milliseconds ([int]$operation.milliseconds) }
                'wait_for_action_signal' {
                    if ([string]::IsNullOrWhiteSpace($ActionSignalPath)) {
                        throw "Step '$stepId' requires a live action-signal path."
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
                if (-not [MonsterCoachPlayerInputBridge]::OwnsForeground($GameWindow)) {
                    throw [System.OperationCanceledException]::new(
                        "Player took over game focus during '$($operation.kind)' for '$stepId'.")
                }
                if ($operation.kind -eq 'wait_for_action_signal') {
                    throw [System.TimeoutException]::new(
                        "Timed out waiting for the expected action transition during '$stepId'.")
                }
                throw [System.InvalidOperationException]::new(
                    "Could not send '$($operation.kind)' for '$stepId'.")
            }
        }
    } finally {
        [MonsterCoachPlayerInputBridge]::ReleaseAllowlistedInputs()
    }
}

Export-ModuleMember -Function Get-LongSwordDefaultInputPlan, Get-LongSwordCurrentInputPlan, `
    Resolve-MonsterCoachInputBindings, Initialize-MonsterCoachInputBridge, `
    Invoke-LongSwordInputStep, Wait-MonsterCoachActionSignal
