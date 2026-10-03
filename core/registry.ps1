<#
  Open365 动作注册表 —— ActionParity 0.5.0 / 影核协议的唯一真相源。

  纪律（与 docs/架构约定.md 一致）：
    * engine/*.ps1 之间仍然零引用；本文件只被 core/action-core.ps1 点引用。
    * 引擎不知道注册表存在 —— 依赖方向永远是 core -> engine，绝不反向。
    * 根目录 action-parity.json 由本注册表生成，不手写；
      tests/test-action-parity.ps1 会对比两者，防止文档漂移。

  每条记录里 invoke/params/requires_admin 是本地执行细节，不进公开清单；
  其余字段原样进 ActionParity 清单。
#>

function Get-Open365Application {
    $root = Split-Path $PSScriptRoot -Parent
    $ver = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $ver) { $ver = '0.0.0' }
    [ordered]@{
        id          = 'org.open365.maintenance'
        name        = 'Open365'
        version     = $ver.Trim()
        description = '无广告、无捆绑、不联网上传的 Windows 维护工具：GUI、CLI 与 AI 共用同一个动作核心。'
        source      = 'https://github.com/dongsheng123132/Open365'
    }
}

function Get-Open365Surfaces {
    @(
        [ordered]@{
            id                  = 'desktop'
            kind                = 'gui'
            reachability        = 'in-process'
            required_for_parity = $true
            test_driver         = 'windows-uia'
            description         = 'Open365.exe 管理中心（WinForms）。每个已同源的按钮带稳定 AccessibleName，供 UI Automation 与静态绑定检查使用。'
        },
        [ordered]@{
            id                  = 'cli'
            kind                = 'cli'
            reachability        = 'external'
            required_for_parity = $true
            description         = '通用动作 CLI：open365.ps1 action list/describe/run/manifest/verify，输出稳定 JSON 信封。'
        },
        [ordered]@{
            id                  = 'legacy-cli'
            kind                = 'cli'
            reachability        = 'external'
            required_for_parity = $false
            exclusion_reason    = '保留既有 engine/*.ps1 命令作为兼容入口；标准同源入口是 core/action-core.ps1。'
            description         = '既有引擎命令 engine/*.ps1 <action> -Json。保留为兼容别名，语义与动作核心一致。'
        },
        [ordered]@{
            id                  = 'test'
            kind                = 'test'
            reachability        = 'in-process'
            required_for_parity = $false
            description         = '无头契约测试：tests/test-action-parity.ps1 直接驱动动作核心，不需要窗口。'
        }
    )
}

function New-Open365Effects {
    param(
        [string]$Class = 'read',
        [string]$Risk = 'low',
        [bool]$Reversible = $true,
        [string]$Confirmation = 'never',
        [bool]$Audit = $false,
        [string]$Rollback,
        [string]$Notes
    )
    $e = [ordered]@{
        class          = $Class
        risk           = $Risk
        reversible     = $Reversible
        confirmation   = $Confirmation
        audit_required = $Audit
    }
    if ($Rollback) { $e['rollback_action'] = $Rollback }
    if ($Notes) { $e['notes'] = $Notes }
    return $e
}

function New-Open365Execution {
    param([int]$TimeoutMs = 120000, [bool]$Idempotent = $true)
    [ordered]@{
        headless        = $true
        headless_evidence = 'tests/verify-action-parity.ps1'
        idempotent      = $Idempotent
        cancellable     = $false
        timeout_ms      = $TimeoutMs
        progress_events = $false
    }
}

function New-Open365Binding {
    param([string]$Surface, [string]$Target, [string]$Test)
    $b = [ordered]@{ surface = $Surface; target = $Target }
    if ($Test) { $b['test'] = $Test }
    return $b
}

# ---------------------------------------------------------------------------
#  动作注册表
# ---------------------------------------------------------------------------

function Get-Open365ActionRegistry {
    $guiTest = 'tests/verify-action-parity.ps1'
    $cliTest = 'tests/verify-action-parity.ps1'
    $legacyTest = 'tests/verify-action-parity.ps1'

    @(
        # ---------------- security.check ----------------
        [ordered]@{
            id          = 'security.check'
            title       = '安全三道防线体检'
            description = '只读检查 Windows Defender 实时防护、防火墙三套配置与 Windows Update 服务，给出结论、问题清单和建议动作。'
            tags        = @('security', 'read', 'diagnose')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{}
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('timestamp', 'defender', 'firewall', 'update', 'verdict', 'problems', 'suggestion')
                properties = [ordered]@{
                    timestamp  = [ordered]@{ type = 'string' }
                    defender   = [ordered]@{ type = 'object' }
                    firewall   = [ordered]@{ type = 'object' }
                    update     = [ordered]@{ type = 'object' }
                    verdict    = [ordered]@{ type = 'string' }
                    problems   = [ordered]@{ type = 'array' }
                    suggestion = [ordered]@{ type = @('string', 'null') }
                }
            }
            effects   = New-Open365Effects -Class 'read' -Risk 'low' -Reversible $true -Confirmation 'never' -Audit $false
            execution = New-Open365Execution -TimeoutMs 120000
            invoke    = [ordered]@{ engine = 'security.ps1'; action = 'check' }
            params    = @()
            bindings  = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.SecurityCheck' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run security.check -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:always-json/engine/security.ps1 check -Json' $legacyTest)
            )
        },

        # ---------------- network.diagnose ----------------
        [ordered]@{
            id          = 'network.diagnose'
            title       = '网络体检'
            description = '只读检查网卡、网关、DNS、系统代理与连通性，判断“能上微信但打不开网页”一类故障的病因。'
            tags        = @('network', 'read', 'diagnose')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{}
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('timestamp', 'adapters', 'proxy', 'tests', 'verdict', 'suggestion')
                properties = [ordered]@{
                    timestamp  = [ordered]@{ type = 'string' }
                    adapters   = [ordered]@{ type = 'array' }
                    proxy      = [ordered]@{ type = 'object' }
                    tests      = [ordered]@{ type = 'object' }
                    verdict    = [ordered]@{ type = 'string' }
                    suggestion = [ordered]@{ type = @('string', 'null') }
                }
            }
            effects   = New-Open365Effects -Class 'read' -Risk 'low' -Reversible $true -Confirmation 'never' -Audit $false
            execution = New-Open365Execution -TimeoutMs 180000
            invoke    = [ordered]@{ engine = 'network.ps1'; action = 'diagnose' }
            params    = @()
            bindings  = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.NetworkDiagnose' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run network.diagnose -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:always-json/engine/network.ps1 diagnose -Json' $legacyTest)
            )
        },

        # ---------------- cleaner.scan ----------------
        [ordered]@{
            id          = 'cleaner.scan'
            title       = '垃圾扫描'
            description = '只扫描不删除：按类别统计临时文件、缓存、回收站等可释放空间。'
            tags        = @('cleaner', 'read', 'scan')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{}
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('spec', 'kind', 'observation_id', 'observed_at', 'policy_revision', 'items', 'total_bytes', 'total_human')
                properties = [ordered]@{
                    spec            = [ordered]@{ type = 'string' }
                    kind            = [ordered]@{ type = 'string' }
                    observation_id  = [ordered]@{ type = 'string' }
                    observed_at     = [ordered]@{ type = 'string' }
                    policy_revision = [ordered]@{ type = 'string' }
                    items           = [ordered]@{
                        type  = 'array'
                        items = [ordered]@{
                            type       = 'object'
                            required   = @('key', 'name', 'bytes', 'files', 'human', 'path', 'observation', 'policy')
                            properties = [ordered]@{
                                key         = [ordered]@{ type = 'string' }
                                name        = [ordered]@{ type = 'string' }
                                bytes       = [ordered]@{ type = 'integer' }
                                files       = [ordered]@{ type = 'integer' }
                                human       = [ordered]@{ type = 'string' }
                                path        = [ordered]@{ type = 'string' }
                                observation = [ordered]@{ type = 'object' }
                                policy      = [ordered]@{ type = 'object' }
                            }
                        }
                    }
                    total_bytes     = [ordered]@{ type = 'integer' }
                    total_human     = [ordered]@{ type = 'string' }
                }
            }
            effects   = New-Open365Effects -Class 'read' -Risk 'low' -Reversible $true -Confirmation 'never' -Audit $false
            execution = New-Open365Execution -TimeoutMs 300000
            invoke    = [ordered]@{ engine = 'cleaner.ps1'; action = 'scan' }
            params    = @()
            bindings  = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.CleanerScan' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run cleaner.scan -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:always-json/engine/cleaner.ps1 scan -Json' $legacyTest)
            )
        },

        # ---------------- cleaner.plan ----------------
        [ordered]@{
            id          = 'cleaner.plan'
            title       = '空间治理计划'
            description = '把选中的空间对象编译成治理计划，计算 plan_id 与预计释放量；只读观察，不改系统。'
            tags        = @('cleaner', 'read', 'plan')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{
                    keys         = [ordered]@{ type = 'string'; description = '逗号分隔的 key 集合；不传则只选 default_selected=true 且当前 bytes>0 的项。' }
                    requested_by = [ordered]@{ type = 'string'; description = '请求来源声明，仅用于审计说明，不是授权凭证。' }
                }
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('kind', 'plan_id', 'policy_revision', 'created_at', 'items', 'estimated_bytes', 'risk_summary', 'contains_irreversible', 'requires_human_confirmation')
                properties = [ordered]@{
                    spec                        = [ordered]@{ type = 'string' }
                    kind                        = [ordered]@{ type = 'string' }
                    plan_id                     = [ordered]@{ type = 'string' }
                    policy_revision              = [ordered]@{ type = 'string' }
                    created_at                   = [ordered]@{ type = 'string' }
                    requested_by                 = [ordered]@{ type = @('string', 'null') }
                    keys                         = [ordered]@{ type = 'string' }
                    items                        = [ordered]@{ type = 'array' }
                    estimated_bytes              = [ordered]@{ type = 'integer' }
                    estimated_human              = [ordered]@{ type = 'string' }
                    risk_summary                 = [ordered]@{ type = 'object' }
                    contains_irreversible        = [ordered]@{ type = 'boolean' }
                    requires_human_confirmation  = [ordered]@{ type = 'boolean' }
                }
            }
            effects   = New-Open365Effects -Class 'read' -Risk 'low' -Reversible $true -Confirmation 'never' -Audit $false
            execution = New-Open365Execution -TimeoutMs 300000
            invoke    = [ordered]@{ engine = 'cleaner.ps1'; action = 'plan' }
            params    = @(
                # verify 探针不传 keys：假 key 会被引擎按契约判为 invalid_keys。
                # 不传就走「默认选中且当前有体积」的路径，才是真正跑了一遍计划编译。
                [ordered]@{ name = 'keys'; arg = '-Keys'; required = $false; verify_probe = '@omit' },
                [ordered]@{ name = 'requested_by'; arg = '-RequestedBy'; required = $false; verify_probe = 'action-parity-verify' }
            )
            bindings  = @(
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run cleaner.plan -InputJson {"keys":"<keys>"} -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:always-json/engine/cleaner.ps1 plan -Json' $legacyTest)
            )
        },

        # ---------------- cleaner.apply ----------------
        [ordered]@{
            id          = 'cleaner.apply'
            title       = '执行空间治理'
            description = '执行已形成且与当前策略一致的空间治理计划；按 request_id 幂等并写入意图与结果收据。'
            tags        = @('cleaner', 'write', 'irreversible')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                required             = @('keys', 'plan_id', 'request_id')
                properties           = [ordered]@{
                    keys         = [ordered]@{ type = 'string'; minLength = 1; description = '逗号分隔的 key 集合。' }
                    plan_id      = [ordered]@{ type = 'string'; minLength = 1; description = 'cleaner.plan 生成的计划 ID。' }
                    request_id   = [ordered]@{ type = 'string'; minLength = 1; description = '调用方提供的稳定幂等请求 ID。' }
                    requested_by = [ordered]@{ type = 'string'; description = '请求来源声明，仅用于审计说明，不是授权凭证。' }
                }
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('status', 'plan_id', 'request_id', 'items', 'total_freed_bytes', 'receipt_written')
                properties = [ordered]@{
                    spec                = [ordered]@{ type = 'string' }
                    kind                = [ordered]@{ type = 'string' }
                    request_id          = [ordered]@{ type = 'string' }
                    request_hash        = [ordered]@{ type = 'string' }
                    plan_id             = [ordered]@{ type = 'string' }
                    policy_revision     = [ordered]@{ type = 'string' }
                    requested_by        = [ordered]@{ type = @('string', 'null') }
                    keys                = [ordered]@{ type = 'string' }
                    started_at          = [ordered]@{ type = 'string' }
                    completed_at        = [ordered]@{ type = 'string' }
                    status              = [ordered]@{ type = 'string' }
                    replayed            = [ordered]@{ type = 'boolean' }
                    items               = [ordered]@{ type = 'array' }
                    failures            = [ordered]@{ type = 'array' }
                    total_freed_bytes   = [ordered]@{ type = 'integer' }
                    total_freed_human   = [ordered]@{ type = 'string' }
                    intent_path         = [ordered]@{ type = 'string' }
                    receipt_path        = [ordered]@{ type = 'string' }
                    receipt_written     = [ordered]@{ type = 'boolean' }
                    warnings            = [ordered]@{ type = 'array' }
                }
            }
            effects   = New-Open365Effects -Class 'write' -Risk 'high' -Reversible $false -Confirmation 'always' -Audit $true `
                -Notes '静态登记取白名单内最高风险。释放量以执行前后观察差值为准。恢复语义多为 regenerate（系统/应用可重建功能，但还原不了原字节）或 none（不可恢复），因此 reversible=false。v1 的确认位只是策略约束，不是可验证的人类授权。'
            execution = New-Open365Execution -TimeoutMs 900000 -Idempotent $true
            requires_admin = $true
            invoke    = [ordered]@{ engine = 'cleaner.ps1'; action = 'apply' }
            params    = @(
                [ordered]@{ name = 'keys'; arg = '-Keys'; required = $true },
                [ordered]@{ name = 'plan_id'; arg = '-PlanId'; required = $true },
                [ordered]@{ name = 'request_id'; arg = '-RequestId'; required = $true },
                [ordered]@{ name = 'requested_by'; arg = '-RequestedBy'; required = $false }
            )
            bindings  = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.CleanerApply' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run cleaner.apply -InputJson {"keys":"<keys>","plan_id":"<plan_id>","request_id":"<request_id>"} -Confirm -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:engine/cleaner.ps1 apply -Keys <keys> -PlanId <plan_id> -RequestId <request_id> -Json' $legacyTest)
            )
        },

        # ---------------- cleaner.history ----------------
        [ordered]@{
            id          = 'cleaner.history'
            title       = '空间治理历史'
            description = '只读查看最近的空间治理收据摘要，并显式报告损坏或不完整的孤儿收据。'
            tags        = @('cleaner', 'read', 'history')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{
                    limit = [ordered]@{ type = 'integer'; minimum = 1; maximum = 100; default = 20 }
                }
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('receipts', 'orphans', 'warnings')
                properties = [ordered]@{
                    spec         = [ordered]@{ type = 'string' }
                    kind         = [ordered]@{ type = 'string' }
                    generated_at = [ordered]@{ type = 'string' }
                    limit        = [ordered]@{ type = 'integer' }
                    receipts     = [ordered]@{ type = 'array' }
                    orphans      = [ordered]@{ type = 'array' }
                    warnings     = [ordered]@{ type = 'array' }
                }
            }
            effects   = New-Open365Effects -Class 'read' -Risk 'low' -Reversible $true -Confirmation 'never' -Audit $false
            execution = New-Open365Execution -TimeoutMs 300000
            invoke    = [ordered]@{ engine = 'cleaner.ps1'; action = 'history' }
            params    = @(
                # limit 是整数，探针必须也是整数：塞字符串会被 input_schema 判为类型不符。
                [ordered]@{ name = 'limit'; arg = '-Limit'; required = $false; verify_probe = 1 }
            )
            bindings  = @(
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run cleaner.history -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:always-json/engine/cleaner.ps1 history -Json' $legacyTest)
            )
        },

        # ---------------- startup.list ----------------
        [ordered]@{
            id          = 'startup.list'
            title       = '列出开机启动项'
            description = '只读列出注册表与启动文件夹中的开机自启项，附带保留/可关建议。'
            tags        = @('startup', 'read', 'list')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{}
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('items')
                properties = [ordered]@{
                    items = [ordered]@{ type = 'array' }
                }
            }
            effects   = New-Open365Effects -Class 'read' -Risk 'low' -Reversible $true -Confirmation 'never' -Audit $false
            execution = New-Open365Execution -TimeoutMs 120000
            invoke    = [ordered]@{ engine = 'startup.ps1'; action = 'list' }
            params    = @()
            bindings  = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.StartupList' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run startup.list -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:always-json/engine/startup.ps1 list -Json' $legacyTest)
            )
        },

        # ---------------- startup.add ----------------
        [ordered]@{
            id = 'startup.add'
            title = '新增开机启动项'
            description = '为当前用户创建登录时启动程序的快捷方式；保留参数，不立即运行，不覆盖同名项。'
            tags = @('startup', 'write', 'reversible')
            input_schema = [ordered]@{
                type = 'object'; additionalProperties = $false
                required = @('name', 'target_path')
                properties = [ordered]@{
                    name = [ordered]@{ type = 'string'; minLength = 1; maxLength = 100 }
                    target_path = [ordered]@{ type = 'string'; minLength = 1 }
                    arguments = [ordered]@{ type = 'string' }
                }
            }
            output_schema = [ordered]@{
                type = 'object'; required = @('ok', 'id', 'state', 'changed')
                properties = [ordered]@{
                    ok = [ordered]@{ type = 'boolean' }
                    id = [ordered]@{ type = 'string' }
                    state = [ordered]@{ type = 'string' }
                    changed = [ordered]@{ type = 'boolean' }
                }
            }
            effects = New-Open365Effects -Class 'write' -Risk 'medium' -Reversible $true -Confirmation 'always' -Audit $true -Rollback 'startup.disable' -Notes '创建当前用户的快捷方式，不立刻运行程序；可禁用以取消自启，快捷方式保留在备份目录。'
            execution = New-Open365Execution -TimeoutMs 30000 -Idempotent $false
            invoke = [ordered]@{ engine = 'startup.ps1'; action = 'add' }
            params = @(
                [ordered]@{ name = 'name'; arg = '-Name'; required = $true },
                [ordered]@{ name = 'target_path'; arg = '-TargetPath'; required = $true },
                [ordered]@{ name = 'arguments'; arg = '-Arguments'; required = $false }
            )
            bindings = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.StartupAdd' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run startup.add -InputFile <json-file> -Confirm -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:engine/startup.ps1 add -Name <name> -TargetPath <path> -Json' $legacyTest)
            )
        },

        # ---------------- startup.disable ----------------
        [ordered]@{
            id          = 'startup.disable'
            title       = '禁用一个开机启动项'
            description = '把指定启动项移到备份位置而不是删除，因此可以用 startup.enable 原样恢复。'
            tags        = @('startup', 'write', 'reversible')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                required             = @('id')
                properties           = [ordered]@{
                    id = [ordered]@{ type = 'string'; minLength = 1; description = 'startup.list 输出中的启动项 id。' }
                }
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('ok', 'id', 'state', 'changed')
                properties = [ordered]@{
                    ok      = [ordered]@{ type = 'boolean' }
                    id      = [ordered]@{ type = 'string' }
                    state   = [ordered]@{ type = 'string' }
                    changed = [ordered]@{ type = 'boolean' }
                }
            }
            effects   = New-Open365Effects -Class 'write' -Risk 'medium' -Reversible $true -Confirmation 'conditional' -Audit $true -Rollback 'startup.enable' -Notes '禁用等于移动到备份键/备份目录，不删除原始命令行。GUI 里点击本身就是确认（可一键还原）；非交互调用必须显式 -Confirm。'
            execution = New-Open365Execution -TimeoutMs 60000 -Idempotent $true
            invoke    = [ordered]@{ engine = 'startup.ps1'; action = 'disable' }
            params    = @(
                [ordered]@{ name = 'id'; arg = '-Id'; required = $true }
            )
            bindings  = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.StartupToggle' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run startup.disable -InputJson {"id":"<id>"} -Confirm -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:engine/startup.ps1 disable -Id <id> -Json' $legacyTest)
            )
        },

        # ---------------- startup.enable ----------------
        [ordered]@{
            id          = 'startup.enable'
            title       = '恢复一个开机启动项'
            description = '把此前被禁用的启动项从备份位置移回原位，是 startup.disable 的回滚动作。'
            tags        = @('startup', 'write', 'reversible')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                required             = @('id')
                properties           = [ordered]@{
                    id = [ordered]@{ type = 'string'; minLength = 1; description = 'startup.list 输出中的启动项 id。' }
                }
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('ok', 'id', 'state', 'changed')
                properties = [ordered]@{
                    ok      = [ordered]@{ type = 'boolean' }
                    id      = [ordered]@{ type = 'string' }
                    state   = [ordered]@{ type = 'string' }
                    changed = [ordered]@{ type = 'boolean' }
                }
            }
            effects   = New-Open365Effects -Class 'write' -Risk 'low' -Reversible $true -Confirmation 'conditional' -Audit $true -Rollback 'startup.disable' -Notes '恢复动作；GUI 点击即确认，非交互调用必须显式 -Confirm。'
            execution = New-Open365Execution -TimeoutMs 60000 -Idempotent $true
            invoke    = [ordered]@{ engine = 'startup.ps1'; action = 'enable' }
            params    = @(
                [ordered]@{ name = 'id'; arg = '-Id'; required = $true }
            )
            bindings  = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.StartupToggle' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run startup.enable -InputJson {"id":"<id>"} -Confirm -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:engine/startup.ps1 enable -Id <id> -Json' $legacyTest)
            )
        },

        # ---------------- process.list ----------------
        [ordered]@{
            id          = 'process.list'
            title       = '列出运行中的进程'
            description = '只读列出进程及内存占用，并标出禁止结束的关键系统进程。'
            tags        = @('process', 'read', 'list')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{}
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('processes', 'count')
                properties = [ordered]@{
                    processes = [ordered]@{ type = 'array' }
                    count     = [ordered]@{ type = 'integer' }
                }
            }
            effects   = New-Open365Effects -Class 'read' -Risk 'low' -Reversible $true -Confirmation 'never' -Audit $false
            execution = New-Open365Execution -TimeoutMs 120000
            invoke    = [ordered]@{ engine = 'process.ps1'; action = 'list' }
            params    = @()
            bindings  = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.ProcessList' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run process.list -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:always-json/engine/process.ps1 list -Json' $legacyTest)
            )
        },

        # ---------------- software.search ----------------
        [ordered]@{
            id          = 'software.search'
            title       = '搜索已安装软件'
            description = '按关键词只读搜索已安装软件，返回卸载所需的 id、名称、版本与发布者。'
            tags        = @('software', 'read', 'search')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                required             = @('query')
                properties           = [ordered]@{
                    query = [ordered]@{ type = 'string'; minLength = 1; description = '软件名关键词。' }
                }
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('apps')
                properties = [ordered]@{
                    apps = [ordered]@{ type = 'array' }
                }
            }
            effects   = New-Open365Effects -Class 'read' -Risk 'low' -Reversible $true -Confirmation 'never' -Audit $false
            execution = New-Open365Execution -TimeoutMs 180000
            invoke    = [ordered]@{ engine = 'uninstall.ps1'; action = 'search' }
            params    = @(
                [ordered]@{ name = 'query'; arg = '-Query'; required = $true }
            )
            bindings  = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.SoftwareSearch' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run software.search -InputJson {"query":"<kw>"} -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:always-json/engine/uninstall.ps1 search <kw> -Json' $legacyTest)
            )
        },

        # ---------------- software.list ----------------
        [ordered]@{
            id          = 'software.list'
            title       = '列出已安装软件'
            description = '只读列出全部已安装软件，字段与 software.search 一致。'
            tags        = @('software', 'read', 'list')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{}
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('apps')
                properties = [ordered]@{
                    apps = [ordered]@{ type = 'array' }
                }
            }
            effects   = New-Open365Effects -Class 'read' -Risk 'low' -Reversible $true -Confirmation 'never' -Audit $false
            execution = New-Open365Execution -TimeoutMs 180000
            invoke    = [ordered]@{ engine = 'uninstall.ps1'; action = 'list' }
            params    = @()
            bindings  = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.SoftwareList' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run software.list -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:always-json/engine/uninstall.ps1 list -Json' $legacyTest)
            )
        },

        # ---------------- focus.status ----------------
        [ordered]@{
            id          = 'focus.status'
            title       = '守夜模式：读当前电源超时'
            description = '只读当前电源计划的熄屏超时，用来说明守夜模式会临时忽略哪些超时。'
            tags        = @('focus', 'read', 'status')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{}
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('display_off_ac_min', 'display_off_dc_min', 'note')
                properties = [ordered]@{
                    display_off_ac_min = [ordered]@{ type = @('number', 'null') }
                    display_off_dc_min = [ordered]@{ type = @('number', 'null') }
                    note               = [ordered]@{ type = 'string' }
                }
            }
            effects   = New-Open365Effects -Class 'read' -Risk 'low' -Reversible $true -Confirmation 'never' -Audit $false
            execution = New-Open365Execution -TimeoutMs 60000
            invoke    = [ordered]@{ engine = 'focus.ps1'; action = 'status' }
            params    = @()
            bindings  = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.FocusStatus' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run focus.status -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:always-json/engine/focus.ps1 status -Json' $legacyTest)
            )
            parity_exceptions = @(
                [ordered]@{
                    surface    = 'desktop'
                    reason     = 'GUI 守夜模式在 Open365Tray.cs 内进程实现，与 engine/focus.ps1 是两份同语义代码，尚未收敛到同一动作核心。'
                    owner      = 'open365-maintainers'
                    review_by  = '2026-10-31'
                }
            )
        },

        # ---------------- update.check ----------------
        [ordered]@{
            id          = 'update.check'
            title       = '检查新版本'
            description = '读本机 VERSION 并向更新源发一个 GET，比对是否有新版本。只读：不下载、不安装、不上传任何本机信息，只在用户主动触发时才联网。'
            tags        = @('update', 'read', 'network')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{
                    url = [ordered]@{ type = @('string', 'null'); description = '自建/内网更新源地址；给了就只查它，不回落 github。' }
                }
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('current', 'latest', 'has_update', 'status', 'download_url', 'source', 'checked_at', 'error')
                properties = [ordered]@{
                    current      = [ordered]@{ type = 'string' }
                    latest       = [ordered]@{ type = @('string', 'null') }
                    has_update   = [ordered]@{ type = 'boolean' }
                    status       = [ordered]@{ type = 'string'; enum = @('up-to-date', 'update-available', 'ahead', 'unknown', 'unreachable') }
                    channel      = [ordered]@{ type = @('string', 'null') }
                    notes        = [ordered]@{ type = @('string', 'null') }
                    published_at = [ordered]@{ type = @('string', 'null') }
                    download_url = [ordered]@{ type = 'string' }
                    source       = [ordered]@{ type = 'string' }
                    checked_at   = [ordered]@{ type = 'string' }
                    error        = [ordered]@{ type = @('string', 'null') }
                }
            }
            effects   = New-Open365Effects -Class 'read' -Risk 'low' -Reversible $true -Confirmation 'never' -Audit $false `
                                           -Notes '唯一一个会主动出网的动作：只发空请求体的 GET，不带机器码/本机信息，且绝不自动下载或替换文件。'
            execution = New-Open365Execution -TimeoutMs 30000
            invoke    = [ordered]@{ engine = 'update.ps1'; action = 'check' }
            params    = @(
                [ordered]@{ name = 'url'; arg = '-Url'; required = $false }
            )
            bindings  = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.UpdateCheck' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run update.check -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:always-json/engine/update.ps1 check -Json' $legacyTest)
            )
        },

        # ---------------- relocate.list ----------------
        [ordered]@{
            id          = 'relocate.list'
            title       = '列出可搬家的软件数据目录'
            description = '只读探测本机微信/QQ/钉钉/企业微信的数据目录：位置、大小、搬家状态（未搬家/已搬家/链接异常）。不读写任何数据。'
            tags        = @('relocate', 'read')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{
                    root         = [ordered]@{ type = @('string', 'null'); description = '数据根目录覆盖（默认真实 Documents；测试/便携用）。' }
                    records_dir  = [ordered]@{ type = @('string', 'null'); description = '搬家记录目录覆盖（默认 %LOCALAPPDATA% 下 Open365/relocate/records）。' }
                }
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('root', 'checked_at', 'items')
                properties = [ordered]@{
                    root       = [ordered]@{ type = 'string' }
                    checked_at = [ordered]@{ type = 'string' }
                    items      = [ordered]@{ type = 'array' }
                }
            }
            effects   = New-Open365Effects -Class 'read' -Risk 'low' -Reversible $true -Confirmation 'never' -Audit $false -Notes '纯只读：列目录、算大小、读记录，全程离线。'
            execution = New-Open365Execution -TimeoutMs 60000
            invoke    = [ordered]@{ engine = 'relocate.ps1'; action = 'list' }
            params    = @(
                [ordered]@{ name = 'root'; arg = '-Root'; required = $false },
                [ordered]@{ name = 'records_dir'; arg = '-RecordsDir'; required = $false }
            )
            bindings  = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.RelocateList' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run relocate.list -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:always-json/engine/relocate.ps1 list -Json' $legacyTest)
            )
        },

        # ---------------- relocate.status ----------------
        [ordered]@{
            id          = 'relocate.status'
            title       = '查看搬家历史与链接健康'
            description = '读搬家记录：每条记录的源/目标/时间、是否已还原、以及仍 active 记录的链接是否健康。只读。'
            tags        = @('relocate', 'read')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{
                    records_dir  = [ordered]@{ type = @('string', 'null'); description = '搬家记录目录覆盖（测试用）。' }
                }
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('records_dir', 'active', 'records')
                properties = [ordered]@{
                    records_dir = [ordered]@{ type = 'string' }
                    active      = [ordered]@{ type = 'integer' }
                    records     = [ordered]@{ type = 'array' }
                }
            }
            effects   = New-Open365Effects -Class 'read' -Risk 'low' -Reversible $true -Confirmation 'never' -Audit $false -Notes '纯只读：只读记录 JSON。'
            execution = New-Open365Execution -TimeoutMs 60000
            invoke    = [ordered]@{ engine = 'relocate.ps1'; action = 'status' }
            params    = @(
                [ordered]@{ name = 'records_dir'; arg = '-RecordsDir'; required = $false }
            )
            bindings  = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.RelocateList' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run relocate.status -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:always-json/engine/relocate.ps1 status -Json' $legacyTest)
            )
        },

        # ---------------- relocate.move ----------------
        [ordered]@{
            id          = 'relocate.move'
            title       = '软件数据搬家'
            description = '把微信/QQ/钉钉/企业微信的数据目录整体【移动】到目标盘，原位置留目录联接（junction），软件无感读写。每次搬家写记录，可 relocate.restore 一键还原。'
            tags        = @('relocate', 'write', 'reversible')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                required             = @('app', 'target')
                properties           = [ordered]@{
                    app          = [ordered]@{ type = 'string'; description = '要搬家的应用 id：wechat / qq / dingtalk / wxwork（引擎侧 ValidateSet 强校验）。' }
                    target       = [ordered]@{ type = 'string'; minLength = 1; description = '目标盘基础目录，如 D:\Open365搬家。不能和源目录同一个盘。' }
                    root         = [ordered]@{ type = @('string', 'null'); description = '数据根目录覆盖（测试/便携用，显式给出时跳过跨盘校验）。' }
                    records_dir  = [ordered]@{ type = @('string', 'null'); description = '搬家记录目录覆盖（测试用）。' }
                }
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('ok', 'app_id', 'app_name', 'target_base', 'moved')
                properties = [ordered]@{
                    ok          = [ordered]@{ type = 'boolean' }
                    app_id      = [ordered]@{ type = 'string' }
                    app_name    = [ordered]@{ type = 'string' }
                    target_base = [ordered]@{ type = 'string' }
                    moved       = [ordered]@{ type = 'array' }
                }
            }
            effects   = New-Open365Effects -Class 'write' -Risk 'medium' -Reversible $true -Confirmation 'conditional' -Audit $true -Rollback 'relocate.restore' -Notes '数据是移动不是复制；robocopy 先复制成功才删源，源没清干净绝不建联接。junction 不需要管理员权限，故 requires_admin=false。'
            execution = New-Open365Execution -TimeoutMs 300000 -Idempotent $false
            requires_admin = $false
            invoke    = [ordered]@{ engine = 'relocate.ps1'; action = 'move' }
            params    = @(
                [ordered]@{ name = 'app'; arg = '-App'; required = $true },
                [ordered]@{ name = 'target'; arg = '-Target'; required = $true },
                [ordered]@{ name = 'root'; arg = '-Root'; required = $false },
                [ordered]@{ name = 'records_dir'; arg = '-RecordsDir'; required = $false }
            )
            bindings  = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.RelocateToggle' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run relocate.move -InputJson {"app":"wechat","target":"D:\\Open365搬家"} -Confirm -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:always-json/engine/relocate.ps1 move -App wechat -Target D:\Open365搬家 -Json' $legacyTest)
            )
        },

        # ---------------- relocate.restore ----------------
        [ordered]@{
            id          = 'relocate.restore'
            title       = '还原软件搬家'
            description = '把此前搬家的数据目录从目标盘搬回原位置并拆除链接，是 relocate.move 的回滚动作。一次还原该应用的全部搬家记录。'
            tags        = @('relocate', 'write', 'reversible')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                required             = @('app')
                properties           = [ordered]@{
                    app          = [ordered]@{ type = 'string'; description = '要还原的应用 id：wechat / qq / dingtalk / wxwork。' }
                    root         = [ordered]@{ type = @('string', 'null'); description = '数据根目录覆盖（测试用）。' }
                    records_dir  = [ordered]@{ type = @('string', 'null'); description = '搬家记录目录覆盖（测试用）。' }
                }
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('ok', 'app_id', 'app_name', 'restored')
                properties = [ordered]@{
                    ok       = [ordered]@{ type = 'boolean' }
                    app_id   = [ordered]@{ type = 'string' }
                    app_name = [ordered]@{ type = 'string' }
                    restored = [ordered]@{ type = 'array' }
                }
            }
            effects   = New-Open365Effects -Class 'write' -Risk 'low' -Reversible $true -Confirmation 'conditional' -Audit $true -Rollback 'relocate.move' -Notes '还原动作：数据搬回原位、拆链接、记录标记已还原（保留历史）。'
            execution = New-Open365Execution -TimeoutMs 300000 -Idempotent $false
            requires_admin = $false
            invoke    = [ordered]@{ engine = 'relocate.ps1'; action = 'restore' }
            params    = @(
                [ordered]@{ name = 'app'; arg = '-App'; required = $true },
                [ordered]@{ name = 'root'; arg = '-Root'; required = $false },
                [ordered]@{ name = 'records_dir'; arg = '-RecordsDir'; required = $false }
            )
            bindings  = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.RelocateToggle' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run relocate.restore -InputJson {"app":"wechat"} -Confirm -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:always-json/engine/relocate.ps1 restore -App wechat -Json' $legacyTest)
            )
        },

        # ---------------- sysinfo.check ----------------
        [ordered]@{
            id          = 'sysinfo.check'
            title       = '系统概况'
            description = '只读探测本机系统信息：系统版本/CPU/内存/磁盘卷/开机时长（字段命名与 本境协议 u-env 的 windows.version / host.hardware / host.disk 契约对齐）。不联网、不写文件、不需要管理员。'
            tags        = @('system', 'read', 'diagnose')
            input_schema = [ordered]@{
                type                 = 'object'
                additionalProperties = $false
                properties           = [ordered]@{}
            }
            output_schema = [ordered]@{
                type     = 'object'
                required = @('ok', 'checked_at', 'system', 'cpu', 'memory', 'disks')
                properties = [ordered]@{
                    ok             = [ordered]@{ type = 'boolean' }
                    checked_at     = [ordered]@{ type = 'string' }
                    system         = [ordered]@{ type = 'object' }
                    cpu            = [ordered]@{ type = 'object' }
                    memory         = [ordered]@{ type = 'object' }
                    disks          = [ordered]@{ type = 'array' }
                    uptime_seconds = [ordered]@{ type = @('integer', 'null') }
                    booted_at      = [ordered]@{ type = @('string', 'null') }
                }
            }
            effects   = New-Open365Effects -Class 'read' -Risk 'low' -Reversible $true -Confirmation 'never' -Audit $false -Notes '纯只读：WMI/注册表探测，全程离线。'
            execution = New-Open365Execution -TimeoutMs 60000
            invoke    = [ordered]@{ engine = 'sysinfo.ps1'; action = 'info' }
            params    = @()
            bindings  = @(
                (New-Open365Binding 'desktop' 'gui:Open365.Gui.SysInfo' $guiTest),
                (New-Open365Binding 'cli' 'cli:open365.ps1 action run sysinfo.check -Json' $cliTest),
                (New-Open365Binding 'legacy-cli' 'cli:always-json/engine/sysinfo.ps1 info -Json' $legacyTest)
            )
        }
    )
}

function Get-Open365StateContract {
    [ordered]@{
        queries = @('security.check', 'network.diagnose', 'cleaner.scan', 'cleaner.plan', 'cleaner.history', 'startup.list', 'process.list', 'software.search', 'software.list', 'focus.status', 'update.check', 'relocate.list', 'relocate.status', 'sysinfo.check')
    }
}
