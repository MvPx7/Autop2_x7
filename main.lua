-- AutoParry v9 | Deepwoken | ASCII-safe
local Players = game:GetService("Players")
local lp = Players.LocalPlayer
if not lp.Character then lp.CharacterAdded:Wait() end

local src = [[
-- +==================================================================+
-- |   AUTO PARRY -- v9                                     |
-- |                                                                  |
-- |   NEW v9:                                                        |
-- |   NEW: Deteccao real de PARRY vs BLOCK via animacao do player   |
-- |        id=5950973195 -> parry confirmado [OK]                      |
-- |        id=4205786624 -> block/guard (muito cedo ou tarde) [BLK]     |
-- |        id=5645212799 -> hit no block (postura subiu) [!]          |
-- |        id=93947622642880 / 9484618709 -> stagger (hit limpo) [HIT] |
-- |   NEW: Estatisticas separadas: Parry / Block / Hit              |
-- |   NEW: Ajuste de timing baseado em parry real (nao so dano)     |
-- |   NEW: Log de resultado por ataque ([OK]/[BLK]/[HIT])                   |
-- |   FIX: track.Stopped nao duplica mais (debounce por ID)        |
-- |   FIX: Ensino pausa autoparry completamente                     |
-- |   FIX: Override por media movel (5 amostras) -- adaga estavel    |
-- |   FIX: Deteccao de arma por MeshPart/Model alem de Tool         |
-- |   FIX: AUTO_DETECT=true por padrao                              |
-- +==================================================================+

local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local lp               = Players.LocalPlayer
local pg               = lp:WaitForChild("PlayerGui")

for _, g in ipairs(pg:GetChildren()) do
    if g.Name == "DWParryUI" then g:Destroy() end
end

-- ==============================================
--  ANIMACOES DO PLAYER (descobertas via detector)
-- ==============================================
local PLAYER_ANIM = {
    -- Parry real: so toca quando o parry funcionou (VFX/flash)
    PARRY_SUCCESS  = { ["5950973195"] = true },

    -- Block/guard: F segurado sem timing certo
    BLOCK          = { ["4205786624"] = true },

    -- Hit no block: levou dano com guard up (postura subiu)
    BLOCK_HIT      = { ["5645212799"] = true },

    -- Stagger: levou hit limpo (sem block nem parry)
    STAGGER        = {
        ["93947622642880"] = true,
        ["9484618709"]     = true,
    },

    -- Guard stance: aparece em parry E block, nao e conclusivo sozinho
    GUARD_STANCE   = { ["5645199546"] = true },
}

-- ==============================================
--  CONFIG
-- ==============================================
local CFG = {
    ATTACK_IDS = {
        ["7600160919"] = true,
        ["7600224169"] = true,
        ["9484850093"] = true,
        ["7318254065"] = true,
        ["5064195992"] = true,
        ["5067105317"] = true,
        ["5067090007"] = true,
        ["7627854272"] = true,
        ["7627889074"] = true,
        ["5950080662"] = true,
    },
    IGNORE_IDS = {
        ["5808247302"] = true,
        ["9598562590"] = true,
        ["9598551746"] = true,
        ["180435571"]  = true,
        ["6037773772"] = true,
        ["9598537410"] = true,
    },

    ID_TIMING_OVERRIDE = {
        ["7318254065"] = 0.55,
    },

    TEACH_HISTORY_SIZE = 5,

    WEAPON_STYLE = {
        heavy = {
            keywords   = { "greataxe","machado","axe","greatsword","claymore",
                           "greatclub","mace","hammer","martelo","warhammer",
                           "club","maul","flail","heavy" },
            timing_mul = 1.20,
            label      = "[*] PESADA",
        },
        medium = {
            keywords   = { "sword","espada","saber","rapier","blade",
                           "scimitar","falchion","longsword","spear","lanca",
                           "lanca","staff","cajado","halberd","medium" },
            timing_mul = 1.00,
            label      = "? MEDIA",
        },
        light = {
            keywords   = { "dagger","adaga","faca","knife","fist",
                           "claw","garra","shortsword","stiletto","tanto",
                           "bow","arco","light","small" },
            timing_mul = 0.80,
            label      = "[o] LEVE",
        },
    },

    PARRY_KEY       = Enum.KeyCode.F,
    PARRY_KEY_HEX   = 0x46,
    PARRY_HOLD      = 0.10,

    ANTICIPATE_INIT = 0.20,
    ANTICIPATE_MIN  = 0.05,
    ANTICIPATE_MAX  = 0.60,
    LEARN_RATE      = 0.35,

    LEARN_WINDOW    = 2.0,
    LEARN_CONFIRM   = 1,

    DEBOUNCE        = 0.55,
    DETECT_RADIUS   = 25,
    TOGGLE_KEY      = Enum.KeyCode.P,

    AUTO_DETECT     = true,
    TEACH_MODE      = false,
    TEACH_PAUSE_AUTOPARRY = true,

    M1_BLOCK_AFTER  = 0.15,

    -- Janela de tempo para associar resultado (parry/block/hit)
    -- ao ultimo ataque detectado
    RESULT_WINDOW   = 1.5,
}

-- ==============================================
--  TEACH HISTORY -- media movel por ID
-- ==============================================
local TeachHistory = {}

local function teachHistoryAdd(id, delay)
    if not TeachHistory[id] then TeachHistory[id] = {} end
    local hist = TeachHistory[id]
    table.insert(hist, delay)
    if #hist > CFG.TEACH_HISTORY_SIZE then table.remove(hist, 1) end
    local sum = 0
    for _, v in ipairs(hist) do sum = sum + v end
    local avg = sum / #hist
    CFG.ID_TIMING_OVERRIDE[id] = avg
    return avg, #hist
end

-- ==============================================
--  ESTADO
-- ==============================================
local State = {
    enabled       = true,
    debounce      = false,
    lastParry     = 0,
    npcConns      = {},
    logLines      = {},

    -- Estatisticas separadas v9
    stats = {
        detected = 0,
        parry    = 0,   -- parry real confirmado
        block    = 0,   -- bloqueou mas nao foi parry
        hit      = 0,   -- levou hit limpo
        learned  = 0,
    },

    anticipate    = CFG.ANTICIPATE_INIT,
    lastAnimTime  = nil,
    pendingParry  = false,
    hitSamples    = {},

    candidates    = {},
    lastSeenId    = nil,
    lastSeenAt    = nil,

    lastNpcAnim   = nil,

    m1Down        = false,
    m1ReleasedAt  = 0,

    -- v9: rastreia o ultimo ataque para associar resultado
    lastAttackAt  = nil,
    lastAttackId  = nil,

    -- v9: evita duplicar Stopped
    stoppedLogged = {},
}

-- ==============================================
--  M1
-- ==============================================
UserInputService.InputBegan:Connect(function(i, processed)
    if processed then return end
    if i.UserInputType == Enum.UserInputType.MouseButton1 then
        State.m1Down = true
    end
end)
UserInputService.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then
        State.m1Down = false
        State.m1ReleasedAt = tick()
    end
end)

local function isM1Blocking()
    if State.m1Down then return true end
    return (tick() - State.m1ReleasedAt) < CFG.M1_BLOCK_AFTER
end

-- ==============================================
--  INPUT -- XENO / FALLBACK
-- ==============================================
local SK = nil
pcall(function()
    if typeof(synthkeyboards) ~= "nil" then SK = synthkeyboards end
end)
local inputMethod = SK and "Xeno synthkeyboards" or "fallback"

local function doParry()
    if SK then
        pcall(function()
            SK:KeyDown(CFG.PARRY_KEY_HEX)
            task.wait(CFG.PARRY_HOLD)
            SK:KeyUp(CFG.PARRY_KEY_HEX)
        end)
    else
        pcall(function()
            if type(keypress) == "function" then
                keypress(CFG.PARRY_KEY_HEX)
                task.wait(CFG.PARRY_HOLD)
                keyrelease(CFG.PARRY_KEY_HEX)
            end
        end)
        pcall(function()
            local VIM = game:GetService("VirtualInputManager")
            VIM:SendKeyEvent(true,  CFG.PARRY_KEY, false, game)
            task.wait(CFG.PARRY_HOLD)
            VIM:SendKeyEvent(false, CFG.PARRY_KEY, false, game)
        end)
    end
end

-- ==============================================
--  CORES
-- ==============================================
local C = {
    bg     = Color3.fromRGB(8,  10, 16),
    panel  = Color3.fromRGB(14, 18, 26),
    border = Color3.fromRGB(40, 55, 90),
    accent = Color3.fromRGB(80, 160,255),
    green  = Color3.fromRGB(55, 215,110),
    red    = Color3.fromRGB(215, 60, 60),
    yellow = Color3.fromRGB(255,205, 50),
    purple = Color3.fromRGB(160, 90,255),
    orange = Color3.fromRGB(255,140, 40),
    teal   = Color3.fromRGB(40, 210,180),
    muted  = Color3.fromRGB(85, 105,145),
    white  = Color3.fromRGB(255,255,255),
    logBg  = Color3.fromRGB(5,   7, 12),
    pink   = Color3.fromRGB(255, 100, 200),
    gray   = Color3.fromRGB(180, 180, 180),
    blue   = Color3.fromRGB(100, 180, 255),
}

-- ==============================================
--  UI HELPERS
-- ==============================================
local sg = Instance.new("ScreenGui")
sg.Name="DWParryUI"; sg.ResetOnSpawn=false
sg.ZIndexBehavior=Enum.ZIndexBehavior.Sibling
sg.IgnoreGuiInset=true

local function mkCorner(p,r)
    local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,r or 6); c.Parent=p
end
local function mkStroke(p,col,th)
    local s=Instance.new("UIStroke"); s.Color=col or C.border
    s.Thickness=th or 1; s.ApplyStrokeMode=Enum.ApplyStrokeMode.Border; s.Parent=p; return s
end
local function mkFrame(p,sz,pos,col,tr)
    local f=Instance.new("Frame"); f.Size=sz; f.Position=pos or UDim2.new(0,0,0,0)
    f.BackgroundColor3=col or C.panel; f.BackgroundTransparency=tr or 0
    f.BorderSizePixel=0; f.Parent=p; return f
end
local function mkLabel(p,txt,sz,pos,col,fs,xa,font)
    local l=Instance.new("TextLabel"); l.BackgroundTransparency=1
    l.Size=sz; l.Position=pos or UDim2.new(0,0,0,0); l.Text=txt or ""
    l.TextColor3=col or C.white; l.TextSize=fs or 12
    l.Font=font or Enum.Font.GothamBold
    l.TextXAlignment=xa or Enum.TextXAlignment.Left
    l.TextTruncate=Enum.TextTruncate.AtEnd; l.Parent=p; return l
end
local function mkBtn(p,txt,sz,pos,bg)
    local b=Instance.new("TextButton"); b.Size=sz; b.Position=pos
    b.BackgroundColor3=bg; b.Text=txt; b.TextColor3=C.white
    b.TextSize=11; b.Font=Enum.Font.GothamBold
    b.BorderSizePixel=0; b.Parent=p; mkCorner(b,5)
    b.MouseEnter:Connect(function()
        TweenService:Create(b,TweenInfo.new(0.12),{BackgroundColor3=bg:Lerp(C.white,0.15)}):Play()
    end)
    b.MouseLeave:Connect(function()
        TweenService:Create(b,TweenInfo.new(0.12),{BackgroundColor3=bg}):Play()
    end)
    return b
end

-- ==============================================
--  UI -- ESTRUTURA
-- ==============================================
local Main = mkFrame(sg, UDim2.new(0,320,0,660), UDim2.new(1,-340,0,60), C.bg)
mkCorner(Main,10)
local mainStroke = mkStroke(Main, C.border, 1)

-- Titlebar
local TBar = mkFrame(Main, UDim2.new(1,0,0,34), UDim2.new(0,0,0,0), C.panel)
mkCorner(TBar,10)
mkFrame(TBar, UDim2.new(1,0,0,2), UDim2.new(0,0,1,-2), C.accent)
mkLabel(TBar,"[ATK]",UDim2.new(0,26,1,0),UDim2.new(0,6,0,0),C.accent,15,Enum.TextXAlignment.Center)
mkLabel(TBar,"AUTO PARRY",UDim2.new(0,180,1,0),UDim2.new(0,36,0,0),C.white,12)
mkLabel(TBar,"v9",UDim2.new(0,30,1,0),UDim2.new(1,-100,0,0),C.orange,10,Enum.TextXAlignment.Right)

local Pill = mkFrame(TBar,UDim2.new(0,62,0,18),UDim2.new(1,-138,0,8),C.green)
mkCorner(Pill,10)
local PillLbl = mkLabel(Pill,"* ATIVO",UDim2.new(1,0,1,0),UDim2.new(0,0,0,0),C.bg,10,Enum.TextXAlignment.Center)

local XBtn = Instance.new("TextButton")
XBtn.Size=UDim2.new(0,26,0,20); XBtn.Position=UDim2.new(1,-30,0,7)
XBtn.BackgroundColor3=Color3.fromRGB(150,35,35); XBtn.Text="X"
XBtn.TextColor3=C.white; XBtn.TextSize=12; XBtn.Font=Enum.Font.GothamBold
XBtn.BorderSizePixel=0; XBtn.Parent=TBar; mkCorner(XBtn,4)
XBtn.MouseButton1Click:Connect(function() sg:Destroy() end)

-- Drag
do
    local drag,ds,dp=false,nil,nil
    TBar.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 then
            drag=true; ds=i.Position; dp=Main.Position end
    end)
    TBar.InputEnded:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=false end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if drag and i.UserInputType==Enum.UserInputType.MouseMovement then
            local d=i.Position-ds
            Main.Position=UDim2.new(dp.X.Scale,dp.X.Offset+d.X,dp.Y.Scale,dp.Y.Offset+d.Y)
        end
    end)
end

-- ==============================================
--  STATS v9 -- 4 blocos: DETECT / PARRY / BLOCK / HIT
-- ==============================================
local StF = mkFrame(Main,UDim2.new(1,-16,0,52),UDim2.new(0,8,0,42),C.panel)
mkCorner(StF,8); mkStroke(StF,C.border)

local function statBlock(parent,x,w,lbl,accent)
    local b=mkFrame(parent,UDim2.new(0,w,1,-10),UDim2.new(0,x,0,5),C.bg)
    b.BackgroundTransparency=1
    mkLabel(b,lbl,UDim2.new(1,0,0,17),UDim2.new(0,0,0,0),C.muted,9,Enum.TextXAlignment.Center)
    local v=mkLabel(b,"0",UDim2.new(1,0,0,22),UDim2.new(0,0,0,16),accent,18,Enum.TextXAlignment.Center)
    v.Font=Enum.Font.GothamBold; return v
end

local DetV  = statBlock(StF,4,   70,"DETECTADOS",C.accent)
local ParV  = statBlock(StF,78,  70,"[OK] PARRY",  C.green)
local BlkV  = statBlock(StF,152, 70,"[BLK] BLOCK",  C.blue)
local HitV  = statBlock(StF,226, 70,"[HIT] HIT",    C.red)
mkFrame(StF,UDim2.new(0,1,1,-12),UDim2.new(0,74,0,6),C.border)
mkFrame(StF,UDim2.new(0,1,1,-12),UDim2.new(0,148,0,6),C.border)
mkFrame(StF,UDim2.new(0,1,1,-12),UDim2.new(0,222,0,6),C.border)

-- Painel calibracao
local CalF = mkFrame(Main,UDim2.new(1,-16,0,54),UDim2.new(0,8,0,102),C.panel)
mkCorner(CalF,8); mkStroke(CalF,C.orange,1)
mkLabel(CalF,"[T] CALIBRACAO ADAPTATIVA",UDim2.new(1,-10,0,14),UDim2.new(0,8,0,4),C.orange,10)
local AntRow = mkFrame(CalF,UDim2.new(1,-16,0,16),UDim2.new(0,8,0,20),C.bg)
AntRow.BackgroundTransparency=1
mkLabel(AntRow,"ANTECIPA:",UDim2.new(0,70,1,0),UDim2.new(0,0,0,0),C.muted,11)
local AntLbl = mkLabel(AntRow,string.format("%.3fs",State.anticipate),UDim2.new(0,80,1,0),UDim2.new(0,72,0,0),C.orange,13)
AntLbl.Font=Enum.Font.GothamBold
mkLabel(AntRow,"AMOSTRAS:",UDim2.new(0,70,1,0),UDim2.new(0,170,0,0),C.muted,11)
local SmpLbl = mkLabel(AntRow,"0",UDim2.new(0,40,1,0),UDim2.new(0,242,0,0),C.yellow,13)
SmpLbl.Font=Enum.Font.GothamBold
local AvgRow = mkFrame(CalF,UDim2.new(1,-16,0,16),UDim2.new(0,8,0,36),C.bg)
AvgRow.BackgroundTransparency=1
mkLabel(AvgRow,"HIT MEDIO:",UDim2.new(0,70,1,0),UDim2.new(0,0,0,0),C.muted,11)
local AvgLbl = mkLabel(AvgRow,"aguardando...",UDim2.new(1,0,1,0),UDim2.new(0,72,0,0),C.purple,11)
AvgLbl.Font=Enum.Font.GothamBold

-- Painel aprendizado
local LrnF = mkFrame(Main,UDim2.new(1,-16,0,42),UDim2.new(0,8,0,164),C.panel)
mkCorner(LrnF,8); mkStroke(LrnF,C.teal,1)
mkLabel(LrnF,"[ID] APRENDIZADO DE IDs",UDim2.new(1,-10,0,14),UDim2.new(0,8,0,4),C.teal,10)
local LrnRow = mkFrame(LrnF,UDim2.new(1,-16,0,16),UDim2.new(0,8,0,22),C.bg)
LrnRow.BackgroundTransparency=1
mkLabel(LrnRow,"STATUS:",UDim2.new(0,55,1,0),UDim2.new(0,0,0,0),C.muted,11)
local LrnLbl = mkLabel(LrnRow,"monitorando...",UDim2.new(1,0,1,0),UDim2.new(0,58,0,0),C.teal,11)
LrnLbl.Font=Enum.Font.GothamBold

-- Painel Arma
local WpnF = mkFrame(Main,UDim2.new(1,-16,0,44),UDim2.new(0,8,0,214),C.panel)
mkCorner(WpnF,5); mkStroke(WpnF, Color3.fromRGB(255,120,50), 1)
mkLabel(WpnF,"[WPN] ARMA NPC:",UDim2.new(0,68,1,0),UDim2.new(0,8,0,2),C.orange,10)
local WpnLbl = mkLabel(WpnF,"--",UDim2.new(0,180,0,18),UDim2.new(0,82,0,2),C.white,11)
WpnLbl.Font=Enum.Font.GothamBold
mkLabel(WpnF,"ESTILO:",UDim2.new(0,50,1,0),UDim2.new(0,8,0,24),C.muted,10)
local StyleLbl = mkLabel(WpnF,"--",UDim2.new(0,200,0,16),UDim2.new(0,60,0,24),C.gray,11)
StyleLbl.Font=Enum.Font.GothamBold

-- M1
local M1F = mkFrame(Main,UDim2.new(1,-16,0,20),UDim2.new(0,8,0,262),C.panel)
mkCorner(M1F,5); mkStroke(M1F,C.border)
mkLabel(M1F,"[M1] M1:",UDim2.new(0,40,1,0),UDim2.new(0,8,0,0),C.muted,10)
local M1Lbl = mkLabel(M1F,"livre",UDim2.new(0,60,1,0),UDim2.new(0,50,0,0),C.green,10)
M1Lbl.Font=Enum.Font.GothamBold
mkLabel(M1F,"TARGET:",UDim2.new(0,45,1,0),UDim2.new(0,120,0,0),C.muted,10)
local NpcLbl = mkLabel(M1F,"--",UDim2.new(0,120,1,0),UDim2.new(0,168,0,0),C.accent,10)
NpcLbl.Font=Enum.Font.GothamBold

local LastF = mkFrame(Main,UDim2.new(1,-16,0,20),UDim2.new(0,8,0,286),C.panel)
mkCorner(LastF,5); mkStroke(LastF,C.border)
mkLabel(LastF,"LAST ID:",UDim2.new(0,52,1,0),UDim2.new(0,8,0,0),C.muted,10)
local LastIdLbl = mkLabel(LastF,"--",UDim2.new(0,200,1,0),UDim2.new(0,64,0,0),C.yellow,10)
LastIdLbl.Font=Enum.Font.GothamBold

-- v9: ultimo resultado
local ResF = mkFrame(Main,UDim2.new(1,-16,0,20),UDim2.new(0,8,0,310),C.panel)
mkCorner(ResF,5); mkStroke(ResF,C.border)
mkLabel(ResF,"RESULTADO:",UDim2.new(0,70,1,0),UDim2.new(0,8,0,0),C.muted,10)
local ResLbl = mkLabel(ResF,"aguardando...",UDim2.new(0,200,1,0),UDim2.new(0,80,0,0),C.muted,10)
ResLbl.Font=Enum.Font.GothamBold

local InpF = mkFrame(Main,UDim2.new(1,-16,0,20),UDim2.new(0,8,0,334),C.panel)
mkCorner(InpF,5); mkStroke(InpF,C.border)
mkLabel(InpF,"INPUT:",UDim2.new(0,45,1,0),UDim2.new(0,8,0,0),C.muted,10)
local InpLbl = mkLabel(InpF,"detectando...",UDim2.new(0,220,1,0),UDim2.new(0,55,0,0),C.purple,10)
InpLbl.Font=Enum.Font.GothamBold

-- Botoes
local BRow = mkFrame(Main,UDim2.new(1,-16,0,26),UDim2.new(0,8,0,362))
BRow.BackgroundTransparency=1
local TogBtn  = mkBtn(BRow,"[||] DESATIVAR",UDim2.new(0,94,1,0),UDim2.new(0,0,0,0),  Color3.fromRGB(30,65,140))
local ResBtn  = mkBtn(BRow,"[RSC] RESCAN",  UDim2.new(0,76,1,0),UDim2.new(0,100,0,0), Color3.fromRGB(25,70,40))
local AutoBtn = mkBtn(BRow,"AUTO:ON",    UDim2.new(0,76,1,0),UDim2.new(0,182,0,0), Color3.fromRGB(80,50,20))
AutoBtn.BackgroundColor3 = CFG.AUTO_DETECT and Color3.fromRGB(80,50,20) or Color3.fromRGB(60,35,80)
AutoBtn.Text = CFG.AUTO_DETECT and "AUTO:ON" or "AUTO:OFF"

local TeachBtn = mkBtn(Main,"[EDU] ENSINO: OFF",
    UDim2.new(1,-16,0,24), UDim2.new(0,8,0,396), Color3.fromRGB(80,20,100))

local CalBtn = mkBtn(Main,"[RST] RESETAR CALIBRACAO",
    UDim2.new(1,-16,0,22), UDim2.new(0,8,0,426), Color3.fromRGB(70,35,10))

mkFrame(Main,UDim2.new(1,-16,0,1),UDim2.new(0,8,0,456),C.border)

-- Log
local LH = mkFrame(Main,UDim2.new(1,-16,0,20),UDim2.new(0,8,0,462),C.panel)
mkCorner(LH,4)
mkLabel(LH,"  >> LOG",UDim2.new(0.4,0,1,0),UDim2.new(0,0,0,0),C.muted,11)

local CpyBtn = Instance.new("TextButton")
CpyBtn.Size=UDim2.new(0,62,0,16); CpyBtn.Position=UDim2.new(1,-128,0,2)
CpyBtn.BackgroundColor3=Color3.fromRGB(20,45,90); CpyBtn.Text="[CPY] COPIAR"
CpyBtn.TextColor3=C.accent; CpyBtn.TextSize=10; CpyBtn.Font=Enum.Font.GothamBold
CpyBtn.BorderSizePixel=0; CpyBtn.Parent=LH; mkCorner(CpyBtn,4)

local ClrBtn = Instance.new("TextButton")
ClrBtn.Size=UDim2.new(0,58,0,16); ClrBtn.Position=UDim2.new(1,-62,0,2)
ClrBtn.BackgroundColor3=Color3.fromRGB(40,15,15); ClrBtn.Text="X LIMPAR"
ClrBtn.TextColor3=C.red; ClrBtn.TextSize=10; ClrBtn.Font=Enum.Font.GothamBold
ClrBtn.BorderSizePixel=0; ClrBtn.Parent=LH; mkCorner(ClrBtn,4)

local Scroll = Instance.new("ScrollingFrame")
Scroll.Size=UDim2.new(1,-16,0,160); Scroll.Position=UDim2.new(0,8,0,486)
Scroll.BackgroundColor3=C.logBg; Scroll.BorderSizePixel=0
Scroll.ScrollBarThickness=3; Scroll.ScrollBarImageColor3=Color3.fromRGB(40,70,150)
Scroll.CanvasSize=UDim2.new(0,0,0,0); Scroll.AutomaticCanvasSize=Enum.AutomaticSize.Y
Scroll.Parent=Main; mkCorner(Scroll,6); mkStroke(Scroll,C.border)
local ULL=Instance.new("UIListLayout",Scroll)
ULL.SortOrder=Enum.SortOrder.LayoutOrder; ULL.Padding=UDim.new(0,1)
local ULP=Instance.new("UIPadding",Scroll)
ULP.PaddingLeft=UDim.new(0,4); ULP.PaddingTop=UDim.new(0,3)

local FtF=mkFrame(Main,UDim2.new(1,0,0,16),UDim2.new(0,0,1,-16),C.panel)
mkLabel(FtF,"  [P] Toggle  |  [EDU] Ensino pausa autoparry  |  [M1] M1 fix  |  v9",
    UDim2.new(1,0,1,0),UDim2.new(0,0,0,0),C.muted,9)

-- M1 loop
task.spawn(function()
    while sg.Parent do
        if State.m1Down then
            M1Lbl.Text = "? SEGURADO"; M1Lbl.TextColor3 = C.red
        elseif (tick() - State.m1ReleasedAt) < CFG.M1_BLOCK_AFTER then
            M1Lbl.Text = "[...] bloqueando"; M1Lbl.TextColor3 = C.yellow
        else
            M1Lbl.Text = "[OK] livre"; M1Lbl.TextColor3 = C.green
        end
        task.wait(0.05)
    end
end)

-- ==============================================
--  LOG ENGINE
-- ==============================================
local logN = 0
local function addLog(icon, text, col)
    logN = logN + 1
    table.insert(State.logLines, string.format("[%d] %s %s", logN, icon, text))
    local row = mkFrame(Scroll, UDim2.new(1,-4,0,15), UDim2.new(0,0,0,0),
        logN%2==0 and Color3.fromRGB(8,11,18) or Color3.fromRGB(11,14,22))
    row.LayoutOrder = logN
    local il = Instance.new("TextLabel"); il.BackgroundTransparency=1
    il.Size=UDim2.new(0,18,1,0); il.Text=icon; il.TextColor3=col or C.accent
    il.TextSize=11; il.Font=Enum.Font.GothamBold
    il.TextXAlignment=Enum.TextXAlignment.Center; il.Parent=row
    local tl = Instance.new("TextLabel"); tl.BackgroundTransparency=1
    tl.Size=UDim2.new(1,-20,1,0); tl.Position=UDim2.new(0,20,0,0)
    tl.Text=text; tl.TextColor3=col or C.white; tl.TextSize=10
    tl.Font=Enum.Font.Code; tl.TextXAlignment=Enum.TextXAlignment.Left
    tl.TextTruncate=Enum.TextTruncate.AtEnd; tl.Parent=row
    task.defer(function() Scroll.CanvasPosition=Vector2.new(0,math.huge) end)
    print(string.format("[AutoParry] %s %s", icon, text))
end

-- ==============================================
--  CALIBRACAO
-- ==============================================
local function avgSamples()
    if #State.hitSamples == 0 then return nil end
    local s = 0
    for _, v in ipairs(State.hitSamples) do s = s + v end
    return s / #State.hitSamples
end

local function learnTiming(hitDelay)
    table.insert(State.hitSamples, hitDelay)
    if #State.hitSamples > 10 then table.remove(State.hitSamples, 1) end
    local avg = avgSamples()
    SmpLbl.Text = tostring(#State.hitSamples)
    AvgLbl.Text = string.format("%.3fs ate hit", avg)
    local nova = math.clamp(avg - 0.05, CFG.ANTICIPATE_MIN, CFG.ANTICIPATE_MAX)
    State.anticipate = State.anticipate + (nova - State.anticipate) * CFG.LEARN_RATE
    State.anticipate = math.clamp(State.anticipate, CFG.ANTICIPATE_MIN, CFG.ANTICIPATE_MAX)
    AntLbl.Text = string.format("%.3fs", State.anticipate)
    addLog("[~]", string.format("timing: hit=%.3fs -> antecipa=%.3fs", hitDelay, State.anticipate), C.orange)
end

-- ==============================================
--  APRENDIZADO DE IDs
-- ==============================================
local function promoteId(id, source)
    if CFG.ATTACK_IDS[id] then return end
    CFG.ATTACK_IDS[id] = true
    State.stats.learned = State.stats.learned + 1
    LrnLbl.Text = "aprendido: " .. id
    LrnLbl.TextColor3 = C.teal
    addLog("[ID]", string.format("NOVO ID: %s [via %s]", id, source or "auto"), C.teal)
    mainStroke.Color = C.teal
    task.delay(0.3, function()
        TweenService:Create(mainStroke, TweenInfo.new(0.5), {Color=C.border}):Play()
    end)
end

local function registerCandidate(id)
    if CFG.ATTACK_IDS[id] or CFG.IGNORE_IDS[id] then return end
    State.lastSeenId = id
    State.lastSeenAt = tick()
    if not State.candidates[id] then
        State.candidates[id] = { count = 0 }
    end
    LrnLbl.Text = string.format("candidato: %s (%d/%d)", id, State.candidates[id].count, CFG.LEARN_CONFIRM)
    LrnLbl.TextColor3 = C.yellow
    addLog("[?]", string.format("ID desconhecido: %s (visto %dx)", id, State.candidates[id].count), C.yellow)
end

local function confirmCandidate()
    local now = tick()
    if not State.lastSeenId then return end
    if not State.lastSeenAt then return end
    if (now - State.lastSeenAt) > CFG.LEARN_WINDOW then return end
    local id = State.lastSeenId
    State.candidates[id].count = State.candidates[id].count + 1
    addLog("[!]", string.format("ID %s causou dano (%d/%d)", id, State.candidates[id].count, CFG.LEARN_CONFIRM), C.yellow)
    if State.candidates[id].count >= CFG.LEARN_CONFIRM then
        promoteId(id, "dano recebido")
        State.candidates[id] = nil
        State.lastSeenId = nil
        State.lastSeenAt = nil
    end
end

-- ==============================================
--  DETECCAO DE ARMA
-- ==============================================
local function getWeaponStyle(weaponName)
    if not weaponName then return nil, nil, nil end
    local lower = weaponName:lower()
    for _, styleName in ipairs({"light", "medium", "heavy"}) do
        local style = CFG.WEAPON_STYLE[styleName]
        for _, kw in ipairs(style.keywords) do
            if lower:find(kw, 1, true) then
                return styleName, style.label, style.timing_mul
            end
        end
    end
    return "medium", "? MEDIA(?)", 1.00
end

local WEAPON_SCAN_KEYWORDS = {
    "sword","espada","adaga","dagger","axe","machado","greataxe",
    "spear","lanca","lanca","staff","cajado","blade","saber",
    "rapier","club","hammer","mace","faca","knife","bow","arco",
    "claw","garra","fist","halberd","claymore","greatsword",
}

local function getNpcWeaponName(npc)
    for _, obj in ipairs(npc:GetDescendants()) do
        if obj:IsA("Tool") then return obj.Name end
    end
    for _, obj in ipairs(npc:GetDescendants()) do
        if obj:IsA("Model") or obj:IsA("MeshPart") or obj:IsA("Part") then
            local name = obj.Name:lower()
            for _, kw in ipairs(WEAPON_SCAN_KEYWORDS) do
                if name:find(kw, 1, true) then return obj.Name end
            end
        end
    end
    return nil
end

-- ==============================================
--  v9: DETECTOR DE RESULTADO (animacoes do player)
--  Monitora animacoes do player para saber se
--  o autoparry resultou em parry real, block ou hit.
--  FIX: usa tabela de IDs ja registrados para
--  evitar duplicar Stopped.
-- ==============================================
local function onPlayerAnimResult(id)
    -- So processa se teve um ataque recente
    if not State.lastAttackAt then return end
    local age = tick() - State.lastAttackAt
    if age > CFG.RESULT_WINDOW then return end

    if PLAYER_ANIM.PARRY_SUCCESS[id] then
        -- [OK] PARRY REAL confirmado pela animacao do player
        State.stats.parry = State.stats.parry + 1
        ParV.Text = tostring(State.stats.parry)
        ResLbl.Text = "[OK] PARRY REAL"
        ResLbl.TextColor3 = C.green
        addLog("[OK]", string.format("PARRY CONFIRMADO ? id_ataque=%s (%.3fs)", State.lastAttackId or "?", age), C.green)
        mainStroke.Color = C.green
        task.delay(0.3, function()
            TweenService:Create(mainStroke, TweenInfo.new(0.6), {Color=C.border}):Play()
        end)
        -- Timing estava certo -- nao precisa ajustar
        State.lastAttackAt = nil

    elseif PLAYER_ANIM.BLOCK[id] then
        -- [BLK] BLOCK -- F foi apertado mas nao no tempo certo
        State.stats.block = State.stats.block + 1
        BlkV.Text = tostring(State.stats.block)
        ResLbl.Text = "[BLK] BLOCK (timing errado)"
        ResLbl.TextColor3 = C.blue
        addLog("[BLK]", string.format("BLOCK (nao foi parry) ? id_ataque=%s (%.3fs)", State.lastAttackId or "?", age), C.blue)
        -- Block indica timing errado: ajusta calibracao
        if State.lastAnimTime then
            learnTiming(tick() - State.lastAnimTime + 0.05)
        end

    elseif PLAYER_ANIM.BLOCK_HIT[id] then
        -- [!] Hit no block -- levou dano mas estava guardando
        addLog("[!]", "Hit no block -- postura subiu", C.yellow)
        ResLbl.Text = "[!] HIT NO BLOCK"
        ResLbl.TextColor3 = C.yellow

    elseif PLAYER_ANIM.STAGGER[id] then
        -- [HIT] Stagger -- levou hit limpo
        State.stats.hit = State.stats.hit + 1
        HitV.Text = tostring(State.stats.hit)
        ResLbl.Text = "[HIT] HIT LIMPO"
        ResLbl.TextColor3 = C.red
        addLog("[HIT]", string.format("HIT LIMPO ? id_ataque=%s", State.lastAttackId or "?"), C.red)
        confirmCandidate()
        if State.lastAnimTime then
            learnTiming(tick() - State.lastAnimTime)
            State.lastAnimTime = nil
        end
    end
end

local function watchPlayerAnims()
    local char = lp.Character or lp.CharacterAdded:Wait()
    local hum  = char:WaitForChild("Humanoid")
    local anim = hum:WaitForChild("Animator")

    anim.AnimationPlayed:Connect(function(track)
        local id = tostring(track.Animation.AnimationId):match("%d+$") or "0"

        -- Processa resultado (parry/block/hit)
        onPlayerAnimResult(id)

        -- FIX: registra conexao Stopped uma unica vez por track
        local stoppedKey = tostring(track) .. id
        if not State.stoppedLogged[stoppedKey] then
            State.stoppedLogged[stoppedKey] = true
            track.Stopped:Once(function()
                State.stoppedLogged[stoppedKey] = nil
            end)
        end
    end)
end

task.spawn(watchPlayerAnims)
lp.CharacterAdded:Connect(function()
    task.spawn(watchPlayerAnims)
end)

-- ==============================================
--  PARRY -- v9: pausa no Ensino, registra ataque
-- ==============================================
local function fireParry(reason, animTime, idOverride, timingMul)
    if not State.enabled then return end
    if CFG.TEACH_MODE and CFG.TEACH_PAUSE_AUTOPARRY then return end
    if isM1Blocking() then
        addLog("[M1]", "PARRY bloqueado -- M1 pressionado", C.muted)
        return
    end

    local now = tick()
    if (now - State.lastParry) < CFG.DEBOUNCE then return end
    if State.debounce then return end

    State.debounce  = true
    State.lastParry = now
    State.pendingParry = true

    -- Registra o ataque para correlacionar com o resultado
    State.lastAttackAt = now
    State.lastAttackId = reason

    local waitTime = 0
    if idOverride then
        waitTime = (animTime + idOverride) - now
        if waitTime < 0 then waitTime = 0 end
    else
        local avg = avgSamples()
        if avg then
            local mul = timingMul or 1.0
            local adjusted = avg * mul
            waitTime = (animTime + adjusted - State.anticipate) - now
            if waitTime < 0 then waitTime = 0 end
        end
    end

    State.stats.detected = State.stats.detected + 1
    DetV.Text = tostring(State.stats.detected)

    task.spawn(function()
        if waitTime > 0 then
            addLog("[...]", string.format("PARRY em %.3fs ? %s", waitTime, reason), C.yellow)
            task.wait(waitTime)
        end

        if isM1Blocking() then
            addLog("[M1]", "PARRY cancelado -- M1 durante espera", C.muted)
            State.debounce = false
            State.pendingParry = false
            return
        end

        addLog("[>]", string.format("disparou parry ? %s", reason), C.accent)
        mainStroke.Color = C.yellow
        doParry()
        task.delay(CFG.PARRY_HOLD + 0.05, function()
            State.debounce    = false
            State.pendingParry = false
        end)
    end)
end

-- ==============================================
--  DETECCAO DE ANIMACOES DO NPC
-- ==============================================
local function distTo(npc)
    local char = lp.Character
    local pr = char and char:FindFirstChild("HumanoidRootPart")
    local nr = npc:FindFirstChild("HumanoidRootPart") or npc:FindFirstChildWhichIsA("BasePart")
    if pr and nr then return (pr.Position - nr.Position).Magnitude end
    return 999
end

local function monitorNPC(npc)
    if State.npcConns[npc] then return end
    if npc == lp.Character then return end
    local hum = npc:FindFirstChildWhichIsA("Humanoid")
    if not hum then return end
    local anim = hum:FindFirstChildWhichIsA("Animator")
    if not anim then return end

    State.npcConns[npc] = {}

    local conn = anim.AnimationPlayed:Connect(function(track)
        if not State.enabled then return end
        if distTo(npc) > CFG.DETECT_RADIUS then return end

        local id = tostring(track.Animation.AnimationId):match("%d+$") or "0"
        if CFG.IGNORE_IDS[id] then return end

        local weaponName = getNpcWeaponName(npc)
        local styleName, styleLabel, timingMul = getWeaponStyle(weaponName)
        local hasWeapon = (weaponName ~= nil)
        WpnLbl.Text = weaponName or "--"
        WpnLbl.TextColor3 = hasWeapon and C.orange or C.muted
        StyleLbl.Text = styleLabel or "sem arma"
        StyleLbl.TextColor3 = styleName == "heavy" and C.red
                           or styleName == "light"  and C.green
                           or C.accent

        State.lastNpcAnim = {
            id         = id,
            npcName    = npc.Name,
            weaponName = weaponName or "--",
            styleLabel = styleLabel or "--",
            timingMul  = timingMul or 1.0,
            animTime   = tick(),
            known      = CFG.ATTACK_IDS[id] or false,
        }

        if not CFG.ATTACK_IDS[id] and not CFG.IGNORE_IDS[id] then
            registerCandidate(id)
        end

        local idOver = CFG.ID_TIMING_OVERRIDE[id]

        if CFG.ATTACK_IDS[id] or hasWeapon or CFG.AUTO_DETECT then
            local animDetectedAt = tick()
            State.lastAnimTime = animDetectedAt
            NpcLbl.Text = npc.Name
            LastIdLbl.Text = id
            ResLbl.Text = "aguardando resultado..."
            ResLbl.TextColor3 = C.muted

            local reason = id
            if hasWeapon and not CFG.ATTACK_IDS[id] then
                reason = string.format("%s[%s]", styleName or "arma", id)
                promoteId(id, "arma:"..weaponName)
            end

            local extraInfo = idOver and string.format(" [override=%.2fs]", idOver)
                           or styleLabel and string.format(" [%s x%.2f]", styleLabel, timingMul or 1.0)
                           or " [AUTO]"
            addLog("[ATK]", string.format("ATAQUE: %s | id=%s%s", npc.Name, id, extraInfo), C.accent)
            fireParry(reason, animDetectedAt, idOver, timingMul)
            return
        end

        State.lastAnimTime = tick()
        NpcLbl.Text = npc.Name
        LastIdLbl.Text = id .. " (?)"
    end)
    table.insert(State.npcConns[npc], conn)

    local rc; rc = npc.AncestryChanged:Connect(function(_,p)
        if not p then
            for _,c in ipairs(State.npcConns[npc] or {}) do pcall(c.Disconnect,c) end
            State.npcConns[npc] = nil
            pcall(rc.Disconnect, rc)
        end
    end)
    table.insert(State.npcConns[npc], rc)
end

-- ==============================================
--  MONITOR DE DANO (fallback se animacao falhar)
-- ==============================================
local function watchDmg()
    local char = lp.Character or lp.CharacterAdded:Wait()
    local hum  = char:WaitForChild("Humanoid")
    local last = hum.Health
    hum.HealthChanged:Connect(function(hp)
        if hp < last then
            local dmg = math.floor(last - hp)
            -- So loga dano se a animacao de stagger nao ja tratou
            addLog("[HIT]", string.format("Dano -%d recebido", dmg), C.red)
            mainStroke.Color = C.red
            task.delay(0.2, function()
                TweenService:Create(mainStroke, TweenInfo.new(0.4), {Color=C.border}):Play()
            end)
        end
        last = hp
    end)
end
task.spawn(watchDmg)

-- ==============================================
--  MODO ENSINO MANUAL
-- ==============================================
UserInputService.InputBegan:Connect(function(i, processed)
    if processed then return end

    if i.KeyCode == CFG.TOGGLE_KEY then
        State.enabled = not State.enabled
        if State.enabled then
            Pill.BackgroundColor3=C.green; PillLbl.Text="* ATIVO"; TogBtn.Text="[||] DESATIVAR"
        else
            Pill.BackgroundColor3=C.red;   PillLbl.Text="* INATIVO"; TogBtn.Text="[>] ATIVAR"
        end
        addLog("[CFG]", State.enabled and "ATIVADO (P)" or "DESATIVADO (P)", C.muted)
        return
    end

    if CFG.TEACH_MODE and i.KeyCode == CFG.TEACH_KEY then
        local now = tick()
        local ua = State.lastNpcAnim
        if ua and (now - ua.animTime) < 3.0 then
            local manualDelay = now - ua.animTime
            local wasKnown = ua.known and " (ja conhecido)" or " (NOVO)"
            local newAvg, sampleCount = teachHistoryAdd(ua.id, manualDelay)
            addLog("[EDU]", string.format("ENSINO: parry em %.3fs | id=%s%s", manualDelay, ua.id, wasKnown), C.pink)
            addLog("[EDU]", string.format("Media override: %.3fs (%d/%d amostras) -> id=%s", newAvg, sampleCount, CFG.TEACH_HISTORY_SIZE, ua.id), C.pink)
            promoteId(ua.id, "ensino manual")
            mainStroke.Color = C.pink
            task.delay(0.3, function()
                TweenService:Create(mainStroke, TweenInfo.new(0.5), {Color=C.border}):Play()
            end)
            State.lastNpcAnim = nil
        else
            local age = ua and string.format(" (anim tem %.1fs)", now - ua.animTime) or ""
            addLog("[EDU]", "Ensino: sem anim recente do NPC" .. age, C.muted)
        end
    end
end)

-- ==============================================
--  SCAN
-- ==============================================
local function scanAll()
    local n = 0
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Model") and obj ~= lp.Character then
            if obj:FindFirstChildWhichIsA("Humanoid") then
                task.spawn(monitorNPC, obj); n = n + 1
            end
        end
    end
    addLog("[SCN]", string.format("Scan: %d NPCs encontrados", n), C.muted)
end

workspace.DescendantAdded:Connect(function(obj)
    if obj:IsA("Humanoid") and obj.Parent ~= lp.Character then
        task.spawn(monitorNPC, obj.Parent)
    end
end)

-- ==============================================
--  BOTOES
-- ==============================================
local function setStatus(on)
    if on then
        Pill.BackgroundColor3=C.green; PillLbl.Text="* ATIVO"; TogBtn.Text="[||] DESATIVAR"
    else
        Pill.BackgroundColor3=C.red;   PillLbl.Text="* INATIVO"; TogBtn.Text="[>] ATIVAR"
    end
end

TogBtn.MouseButton1Click:Connect(function()
    State.enabled = not State.enabled
    setStatus(State.enabled)
    addLog("[CFG]", State.enabled and "ATIVADO" or "DESATIVADO", C.muted)
end)

ResBtn.MouseButton1Click:Connect(function()
    for npc, conns in pairs(State.npcConns) do
        for _, c in ipairs(conns) do pcall(c.Disconnect, c) end
    end
    State.npcConns = {}
    addLog("[CFG]", "Rescaneando...", C.muted)
    task.spawn(scanAll)
end)

AutoBtn.MouseButton1Click:Connect(function()
    CFG.AUTO_DETECT = not CFG.AUTO_DETECT
    AutoBtn.Text = CFG.AUTO_DETECT and "AUTO:ON" or "AUTO:OFF"
    AutoBtn.BackgroundColor3 = CFG.AUTO_DETECT
        and Color3.fromRGB(80,50,20) or Color3.fromRGB(60,35,80)
    addLog("[CFG]", "AUTO_DETECT: "..(CFG.AUTO_DETECT and "ON" or "OFF"), C.muted)
end)

TeachBtn.MouseButton1Click:Connect(function()
    CFG.TEACH_MODE = not CFG.TEACH_MODE
    if CFG.TEACH_MODE then
        TeachBtn.Text = "[EDU] ENSINO: ON  [autoparry PAUSADO]"
        TeachBtn.BackgroundColor3 = Color3.fromRGB(120,20,160)
        addLog("[EDU]", "MODO ENSINO ATIVADO -- autoparry PAUSADO", C.pink)
        addLog("[EDU]", "NPC ataca -> aperta F na hora certa -> override salvo", C.pink)
        addLog("[EDU]", string.format("Media movel: %d amostras por ID", CFG.TEACH_HISTORY_SIZE), C.pink)
    else
        TeachBtn.Text = "[EDU] ENSINO: OFF"
        TeachBtn.BackgroundColor3 = Color3.fromRGB(80,20,100)
        addLog("[EDU]", "Modo ensino desativado -- autoparry retomado", C.muted)
    end
end)

CalBtn.MouseButton1Click:Connect(function()
    State.anticipate   = CFG.ANTICIPATE_INIT
    State.hitSamples   = {}
    State.lastAnimTime = nil
    State.candidates   = {}
    State.lastSeenId   = nil
    State.lastSeenAt   = nil
    State.lastNpcAnim  = nil
    State.lastAttackAt = nil
    State.lastAttackId = nil
    AntLbl.Text = string.format("%.3fs", State.anticipate)
    SmpLbl.Text = "0"
    AvgLbl.Text = "aguardando..."
    LrnLbl.Text = "monitorando..."
    LrnLbl.TextColor3 = C.teal
    ResLbl.Text = "aguardando..."
    ResLbl.TextColor3 = C.muted
    addLog("[RST]", "Calibracao e candidatos resetados", C.orange)
end)

ClrBtn.MouseButton1Click:Connect(function()
    for _, c in ipairs(Scroll:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    logN = 0; State.logLines = {}
    addLog("[CFG]", "Log limpo.", C.muted)
end)

CpyBtn.MouseButton1Click:Connect(function()
    local text = table.concat(State.logLines, "\n")
    local ok = pcall(function() setclipboard(text) end)
    if ok then
        local orig = CpyBtn.Text
        CpyBtn.Text = "? COPIADO"; CpyBtn.TextColor3 = C.green
        task.delay(1.5, function() CpyBtn.Text = orig; CpyBtn.TextColor3 = C.accent end)
        addLog("[CPY]", string.format("%d linhas copiadas", #State.logLines), C.green)
    else
        addLog("[!]", "setclipboard indisponivel -- veja F9", C.yellow)
        print(table.concat(State.logLines, "\n"))
        CpyBtn.Text = "[!] VER F9"; CpyBtn.TextColor3 = C.yellow
        task.delay(2, function() CpyBtn.Text = "[CPY] COPIAR"; CpyBtn.TextColor3 = C.accent end)
    end
end)

-- ==============================================
--  INIT
-- ==============================================
local nAtk = 0; for _ in pairs(CFG.ATTACK_IDS) do nAtk = nAtk + 1 end
local nIgn = 0; for _ in pairs(CFG.IGNORE_IDS) do nIgn = nIgn + 1 end
local nOvr = 0; for _ in pairs(CFG.ID_TIMING_OVERRIDE) do nOvr = nOvr + 1 end

addLog("[CFG]", "AutoParry v9 iniciado", C.orange)
addLog("[CFG]", string.format("IDs: %d ataques | %d ignorados | %d overrides", nAtk, nIgn, nOvr), C.muted)
addLog("[TGT]", "Deteccao: PARRY(5950973195) / BLOCK(4205786624) / HIT(stagger)", C.green)
addLog("[WPN]", "Estilos: pesada x1.2 | media x1.0 | leve x0.8", C.orange)
addLog("[M1]", "M1 fix ativo -- parry nao dispara enquanto ataca", C.green)
addLog("[EDU]", string.format("Ensino: pausa autoparry | media %d amostras por ID", CFG.TEACH_HISTORY_SIZE), C.pink)
addLog("[NET]", string.format("AUTO_DETECT: %s | DEBOUNCE: %.2fs", CFG.AUTO_DETECT and "ON" or "OFF", CFG.DEBOUNCE), C.teal)
addLog("[CFG]", string.format("antecipacao inicial: %.3fs", State.anticipate), C.muted)

task.delay(0.1, function()
    local cor = SK and C.green or C.yellow
    InpLbl.Text = inputMethod
    InpLbl.TextColor3 = cor
    addLog("[INP]", "Input: " .. inputMethod, cor)
end)

setStatus(State.enabled)
sg.Parent = pg
task.spawn(scanAll)
]]

local fn, err = loadstring(src)
if not fn then
    warn("[AutoParry] Erro de compilacao: " .. tostring(err))
else
    local ok, e2 = pcall(fn)
    if not ok then warn("[AutoParry] Erro de execucao: " .. tostring(e2)) end
end
