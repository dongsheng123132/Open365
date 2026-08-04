<#
  Open365 动作注册表 —— ActionParity 0.1.0 / 影核协议的唯一真相源。

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
            required_for_parity = $true
            test_driver         = 'windows-uia'
            description         = 'Open365.exe 管理中心（WinForms）。每个已同源的按钮带稳定 AccessibleName，供 UI Automation 与静态绑定检查使用。'
        },
        [ordered]@{
            id                  = 'cli'
            kind                = 'cli'
            required_for_parity = $true
            description         = '通用动作 CLI：open365.ps1 action list/describe/run/manifest/verify，输出稳定 JSON 信封。'
        },
        [ordered]@{
            id                  = 'legacy-cli'
            kind                = 'cli'
            required_for_parity = $false
            description         = '既有引擎命令 engine/*.ps1 <action> -Json。保留为兼容别名，语义与动作核心一致。'
        },
        [ordered]@{
            id                  = 'test'
            kind                = 'test'
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
    $guiTest = 'tests/test-action-parity.ps1:gui-binding'
    $cliTest = 'tests/test-action-parity.ps1:cli-parity'
    $legacyTest = 'tests/test-action-parity.ps1:legacy-parity'

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
                required = @('items', 'total_bytes', 'total_human')
                properties = [ordered]@{
                    items       = [ordered]@{ type = 'array' }
                    total_bytes = [ordered]@{ type = 'integer' }
                    total_human = [ordered]@{ type = 'string' }
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
            requires_admin = $true
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
            requires_admin = $true
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
        }
    )
}

function Get-Open365StateContract {
    [ordered]@{
        queries = @('security.check', 'network.diagnose', 'cleaner.scan', 'startup.list', 'process.list', 'software.search', 'software.list', 'focus.status', 'update.check')
    }
}
