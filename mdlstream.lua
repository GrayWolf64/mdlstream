--- MDLStream
-- Sync necessary files of client models to server so that server can initialize models' physics
-- For use with cloud asset related addons
--
-- Specifications:
-- Max file size: 8.75 MB
-- Limited file formats
-- Handshake styled transmission
--
-- !If you are server owner, I suggest you using https://github.com/WilliamVenner/gmsv_workshop/ for better experience
-- You can of course use this as a fallback option
--
-- Possible Workflow: Client Request ==> Server receives Request ==> Server Blinks(acknowledge) ==> Client receives Blink
-- ==> Client sends frame ==> Server receives frame ==> Server builds file(transmisson finished) / Server Blinks ==> Client
-- receives Blink ==> Client sends frame ==> ... Until all frames of file content are fully received, then build(finished)
--
-- @author GrayWolf, RiceMCUT, Wolf109909
-- @license Apache License 2.0
--
-- More on MDL: https://developer.valvesoftware.com/wiki/MDL_(Source)
-- Thanks to https://github.com/ZeqMacaw/Crowbar/tree/master/Crowbar/Core/GameModel for some crucial hints on mdl header1
--
if not gmod or game.SinglePlayer() then return end

mdlstream = {}

---
--* Switches
--
-- `flag_testing`: Disables file existence check serverside
-- `flag_noclui`:  Disables clientside debugger GUI; Directs some terminal(debugger ui) messages to engine console
local flag_testing = true
local flag_noclui  = false

--- Shared konstants(not necessarily)
-- !Without extra indication, all the numbers related to msg sizes are all in 'bytes'
local max_msg_size        = 65536 - 3 - 1 - 3 - 3 - 8 - 10000
-- 3 spared for engine use
-- 1 for determining the response mode
-- #content for the actual partial(sliced) compressed string of byte sequence of target file
-- 3 for #content(slice / frame) length
-- 3 for #content frame ending position
-- 8 for uid(int64:str) of every accepted request, generated on client
-- some bytes spared for testing the most optimal size

--- For clientside compression of bt
-- "~", "^" for extension of representable range
-- TODO: re-arrange it on the fly and sync with sv to achieve minimum strlen
local bs_codec={
    [0] = "a",
    [1] = "b",
    [2] = "c",
    [3] = "d",
    [4] = "e",
    [5] = "f",
    [6] = "g",
    [7] = "h",
    [8] = "i",
    [9] = "j",
    [10] = "k",
    [11] = "l",
    [12] = "m",
    [13] = "n",
    [14] = "o",
    [15] = "p",
    [16] = "q",
    [17] = "r",
    [18] = "s",
    [19] = "t",
    [20] = "u",
    [21] = "v",
    [22] = "w",
    [23] = "x",
    [24] = "y",
    [25] = "z",

    [26] = "!",
    [27] = "\"",
    [28] = "#",
    [29] = "$",
    [30] = "%",
    [31] = "&",
    [32] = "'",
    [33] = "(",
    [34] = ")",
    [35] = "*",
    [36] = "+",
    [37] = ",",
    [38] = "-",
    [39] = ".",
    [40] = "/",
    [41] = ":",
    [42] = ";",
    [43] = "<",
    [44] = "=",
    [45] = ">",
    [46] = "?",
    [47] = "@",
    [48] = "[",
    [49] = "\\",
    [50] = "]",
    [51] = "_",
    [52] = "`",
    [53] = "{",
    [54] = "|",
    [55] = "}",

    [56] = "~a",
    [57] = "~b",
    [58] = "~c",
    [59] = "~d",
    [60] = "~e",
    [61] = "~f",
    [62] = "~g",
    [63] = "~h",
    [64] = "~i",
    [65] = "~j",
    [66] = "~k",
    [67] = "~l",
    [68] = "~m",
    [69] = "~n",
    [70] = "~o",
    [71] = "~p",
    [72] = "~q",
    [73] = "~r",
    [74] = "~s",
    [75] = "~t",
    [76] = "~u",
    [77] = "~v",
    [78] = "~w",
    [79] = "~x",
    [80] = "~y",
    [81] = "~z",

    [82] = "^a",
    [83] = "^b",
    [84] = "^c",
    [85] = "^d",
    [86] = "^e",
    [87] = "^f",
    [88] = "^g",
    [89] = "^h",
    [90] = "^i",
    [91] = "^j",
    [92] = "^k",
    [93] = "^l",
    [94] = "^m",
    [95] = "^n",
    [96] = "^o",
    [97] = "^p",
    [98] = "^q",
    [99] = "^r",
    [100] = "^s",
    [101] = "^t",
    [102] = "^u",
    [103] = "^v",
    [104] = "^w",
    [105] = "^x",
    [106] = "^y",
    [107] = "^z",

    [108] = "~!",
    [109] = "~\"",
    [110] = "~#",
    [111] = "~$",
    [112] = "~%",
    [113] = "~&",
    [114] = "~'",
    [115] = "~(",
    [116] = "~)",
    [117] = "~*",
    [118] = "~+",
    [119] = "~,",
    [120] = "~-",
    [121] = "~.",
    [122] = "~/",
    [123] = "~:",
    [124] = "~;",
    [125] = "~?",
    [126] = "~@",

    [127] = "A",
    [128] = "B",
    [129] = "C",
    [130] = "D",
    [131] = "E",
    [132] = "F",
    [133] = "G",
    [134] = "H",
    [135] = "I",
    [136] = "J",
    [137] = "K",
    [138] = "L",
    [139] = "M",
    [140] = "N",
    [141] = "O",
    [142] = "P",
    [143] = "Q",
    [144] = "R",
    [145] = "S",
    [146] = "T",
    [147] = "U",
    [148] = "V",
    [149] = "W",
    [150] = "X",
    [151] = "Y",
    [152] = "Z",

    [153] = "~A",
    [154] = "~B",
    [155] = "~C",
    [156] = "~D",
    [157] = "~E",
    [158] = "~F",
    [159] = "~G",
    [160] = "~H",
    [161] = "~I",
    [162] = "~J",
    [163] = "~K",
    [164] = "~L",
    [165] = "~M",
    [166] = "~N",
    [167] = "~O",
    [168] = "~P",
    [169] = "~Q",
    [170] = "~R",
    [171] = "~S",
    [172] = "~T",
    [173] = "~U",
    [174] = "~V",
    [175] = "~W",
    [176] = "~X",
    [177] = "~Y",
    [178] = "~Z",

    [179] = "^A",
    [180] = "^B",
    [181] = "^C",
    [182] = "^D",
    [183] = "^E",
    [184] = "^F",
    [185] = "^G",
    [186] = "^H",
    [187] = "^I",
    [188] = "^J",
    [189] = "^K",
    [190] = "^L",
    [191] = "^M",
    [192] = "^N",
    [193] = "^O",
    [194] = "^P",
    [195] = "^Q",
    [196] = "^R",
    [197] = "^S",
    [198] = "^T",
    [199] = "^U",
    [200] = "^V",
    [201] = "^W",
    [202] = "^X",
    [203] = "^Y",
    [204] = "^Z",

    [205] = "^!",
    [206] = "^\"",
    [207] = "^#",
    [208] = "^$",
    [209] = "^%",
    [210] = "^&",
    [211] = "^'",
    [212] = "^(",
    [213] = "^)",
    [214] = "^*",
    [215] = "^+",
    [216] = "^,",
    [217] = "^-",
    [218] = "^.",
    [219] = "^/",
    [220] = "^:",
    [221] = "^;",
    [222] = "^?",
    [223] = "^@",

    [224] = "~1",
    [225] = "~2",
    [226] = "~3",
    [227] = "~4",
    [228] = "~5",
    [229] = "~6",
    [230] = "~7",
    [231] = "~8",
    [232] = "~9",
    [233] = "~0",

    [234] = "^1",
    [235] = "^2",
    [236] = "^3",
    [237] = "^4",
    [238] = "^5",
    [239] = "^6",
    [240] = "^7",
    [241] = "^8",
    [242] = "^9",
    [243] = "^0",

    [244] = "^>",
    [245] = "^<",

    [246] = "1",
    [247] = "2",
    [248] = "3",
    [249] = "4",
    [250] = "5",
    [251] = "6",
    [252] = "7",
    [253] = "8",
    [254] = "9",
    [255] = "0"
}

local tonumber            = tonumber
local isvalid             = IsValid

local netlib_set_receiver = net.Receive
local netlib_start        = net.Start

local netlib_wuint64      = net.WriteUInt64
local netlib_ruint64      = net.ReadUInt64

-- every uint we read and write will be a 24-bit one, max = 16777215, definitely abundant
local netlib_wuint        = function(_uint) net.WriteUInt(_uint, 24) end
local netlib_ruint        = function() return net.ReadUInt(24) end

--- dedicated to read and write response mode, max = 255
--
--   0: Server has refused request(file already exists on server)
--   1: Server has built file and sends an ack for finalization
-- 100: Server has accepted Client's request, awaits the first frame
-- 101: Server awaits subsequent frame
-- 200: Client sends a frame that can be received and built on Server using previously received frames or
--      this request consists only one frame
-- 201: Client sends a frame that requires Server's subsequent frame-save and acknowledgement
local netlib_wuintm       = function(_uint) net.WriteUInt(_uint, 8) end
local netlib_ruintm       = function() return net.ReadUInt(8) end

local str_sub             = string.sub
local str_fmt             = string.format

local tblib_concat        = table.concat
local tblib_remove        = table.remove

local file_size           = file.Size

local mstr                = function(_s) return "MDLStream: " .. _s end

local str_startswith      = function(_s, start) return str_sub(_s, 1, #start) == start end

local file_open           = function(_f, _m, _p)
    local __f = file.Open(_f, _m, _p) if not __f then error("file descriptor invalid", 2) end
    return __f
end

if CLIENT then
    local lzma             = util.Compress

    local netlib_wstring   = net.WriteString
    local netlib_toserver  = net.SendToServer

    local function netlib_wbdata(_bs, _start, _end)
        local _size = #_bs
        if not _end then _end = _size end
        size = _end - _start + 1
        netlib_wuint(size)
        net.WriteData(str_sub(_bs, _start, _end), size)
    end

    local cfile_eof        = FindMetaTable("File").EndOfFile
    local cfile_rbyte      = FindMetaTable("File").ReadByte

    local str_ext_fromfile = string.GetExtensionFromFilename

    local fun_donothing    = function() end

    local realmax_msg_size = max_msg_size

    local max_file_size    = 8750000

    -- TODO: does server really need some of them?
    local file_formats     = {mdl = true, phy = true, vvd = true, ani = true, vtx = true}

    local stdout = stdout or vgui.Create("RichText") stdout:Hide()

    local function stdout_append(_s)
        stdout:InsertColorChange(0, 205, 50, 255) stdout:AppendText(os.date("%H:%M:%S") .. " ")
        stdout:InsertColorChange(0, 0, 0, 225)    stdout:AppendText(_s .. "\n")
    end

    stdout_append("type some chars to reveal suggestions")

    local mdl_determinant = {
        id = {73, 68, 83, 84}, -- "IDST". no "MDLZ"
        versions = {
            --- Known: 4 is "HLAlpha", 6, 10 is "HLStandardSDK" related
            -- 14 is used in "Half-Life SDK", too old that is out of scope of this project
            -- [4] = true, [6]  = true,
            -- [10] = true, [14]   = true,
            [2531] = true, [27] = true, [28] = true, [29] = true,
            [30]   = true, [31] = true, [32] = true, [35] = true, [36] = true, [37] = true,
            [44]   = true, [45] = true, [46] = true, [47] = true, [48] = true, [49] = true,
            [52]   = true, [53] = true, [54] = true, [55] = true, [56] = true, [58] = true, [59] = true
        }
    }

    --- https://github.com/Tieske/pe-parser/blob/master/src/pe-parser.lua
    local function validate_header(_path)
        local _file = file_open(_path, "rb", "GAME")

        if _file:Read(2) == "MZ" then return false end
        _file:Skip(-2)

        --- Currently, only mdl's header check is implemented
        if str_ext_fromfile(_path) ~= "mdl" then return true end

        local function read_cint() return {cfile_rbyte(_file), cfile_rbyte(_file), cfile_rbyte(_file), cfile_rbyte(_file)} end

        local function hext_to_int(_t) return tonumber(str_fmt("0x%x%x%x%x", _t[4], _t[3], _t[2], _t[1])) end

        local studiohdr_t = {
            id = read_cint(), version = read_cint(), checksum = read_cint(), name = _file:Read(64), datalen = read_cint()
        }

        _file:Close()

        if  studiohdr_t.id[1] ~= mdl_determinant.id[1] or studiohdr_t.id[2] ~= mdl_determinant.id[2] or
            studiohdr_t.id[3] ~= mdl_determinant.id[3] or studiohdr_t.id[4] ~= mdl_determinant.id[4] then
            return false
        end

        if not mdl_determinant.versions[hext_to_int(studiohdr_t.version)] then return false end
        if not studiohdr_t.checksum or not #studiohdr_t.checksum == 4     then return false end
        if not studiohdr_t.name                                           then return false end
        if hext_to_int(studiohdr_t.datalen) ~= file_size(_path, "GAME")   then return false end

        return true
    end

    local function bchars_table(_path)
        local chars = {}

        local _file = file_open(_path, "rb", "GAME")

        for i = 1, math.huge do
            if cfile_eof(_file) then break end

            chars[i] = bs_codec[cfile_rbyte(_file)]
        end

        return chars
    end

    local ctemp = ctemp or {}

    local function uidgen() return string.gsub(tostring(SysTime()), "%.", "", 1) end

    -- TODO: clientside postpone frame dispatch when ping too high/unstable, and a state machine serverside
    local function send_request(path, callback)
        assert(isstring(path),                       mstr"'path' is not a string")
        assert(file.Exists(path, "GAME"),            mstr"desired filepath does not exist on client, " .. path)
        assert(file_formats[str_ext_fromfile(path)], mstr"Tries to send unsupported file, "            .. path)

        local size = file_size(path, "GAME")

        assert(size <= max_file_size, mstr"Tries to send file larger than 8.75 MB, "       .. path)
        assert(validate_header(path), mstr"Corrupted or intentionally bad file (header), " .. path)

        if not callback or not isfunction(callback) then callback = fun_donothing end

        local uid = uidgen()

        ctemp[uid] = {[1] = lzma(tblib_concat(bchars_table(path))), [2] = path, [3] = callback}

        netlib_start("mdlstream_req")
        netlib_wstring(path)
        netlib_wuint64(uid)
        netlib_wstring(tostring(size))
        netlib_toserver()
    end

    --- Based on assumptions
    -- we'd better hope that this client's net condition will get better,
    -- otherwise, he will probably wait forever or quit and get some better gear
    local function adjust_max_msg_size()
        if not LocalPlayer() then return end

        local ping = LocalPlayer():Ping()

        if     ping <= 30                 then realmax_msg_size = max_msg_size
        elseif ping >= 31  and ping < 50  then realmax_msg_size = max_msg_size - 5000
        elseif ping >= 51  and ping < 100 then realmax_msg_size = max_msg_size - 15000
        elseif ping >= 101 and ping < 200 then realmax_msg_size = max_msg_size - 27000
        else                                   realmax_msg_size = 20000 end
    end

    local function w_framemode(_exceeds) if not _exceeds then netlib_wuintm(200) else netlib_wuintm(201) end end

    -- @BUFFER_SENSITIVE
    netlib_set_receiver("mdlstream_ack", function()
        local _mode    = netlib_ruintm()
        local uid      = netlib_ruint64()

        if _mode == 0 then
            stdout_append(str_fmt("request rejected(identically sized and named file already exists serverside: %s)", ctemp[uid][2]))
            ctemp[uid] = nil

            return
        elseif _mode == 1 then
            local is_ok = pcall(ctemp[uid][3])

            stdout_append(str_fmt("request finished: %s, callback is_ok = %s", ctemp[uid][2], tostring(is_ok)))

            --- Clears garbage on client's delicate computer
            ctemp[uid] = nil

            return
        end

        netlib_start("mdlstream_frm")

        netlib_wuint64(uid)

        adjust_max_msg_size()

        local _bs = ctemp[uid][1]

        --- May better simplify section below
        local exceeds_max, pos
        if _mode == 100 then
            exceeds_max = #_bs > realmax_msg_size
            w_framemode(exceeds_max)

            if not exceeds_max then
                netlib_wbdata(_bs, 1, nil)
            else
                netlib_wbdata(_bs, 1, realmax_msg_size)
                netlib_wuint(realmax_msg_size)
            end
        elseif _mode == 101 then
            pos         = netlib_ruint()
            exceeds_max = #_bs - pos > realmax_msg_size

            w_framemode(exceeds_max)

            if not exceeds_max then
                netlib_wbdata(_bs, pos + 1, nil)
            else
                local _endpos = pos + realmax_msg_size

                netlib_wbdata(_bs, pos + 1, _endpos)
                netlib_wuint(_endpos)
            end
        end

        netlib_toserver()

        local filename = ctemp[uid][2]

        if exceeds_max then
            if _mode == 100 then
                stdout_append("starting frame sent: " .. filename)
            elseif _mode == 101 then
                stdout_append(str_fmt("progress: %s %u%%", filename, math.floor((pos / #_bs) * 100)))
            end
        else
            if _mode == 100 or _mode == 101 then stdout_append("last frame sent: " .. filename) end
        end
    end)

    mdlstream.SendRequest = send_request

    ---
    --* Debugger part
    --
    if flag_noclui then
        stdout_append = function(_s) print(mstr(_s)) end
        stdout:Remove()

        return
    end

    local surf_set_drawcolor     = surface.SetDrawColor
    local surf_drawrect          = surface.DrawRect
    local surf_drawrect_outline  = surface.DrawOutlinedRect
    local surf_setmaterial       = surface.SetMaterial
    local surf_drawrect_textured = surface.DrawTexturedRect

    concommand.Add("mdt", function()
        local window = vgui.Create("DFrame")
        window:Center() window:SetSize(ScrW() / 2, ScrH() / 2.5)
        window:SetTitle("MDLStream Debugging Tool") window:MakePopup() window:SetDeleteOnClose(false)

        window.lblTitle:SetFont("BudgetLabel")

        local title_push = 0
        window.PerformLayout = function(self)
            if (isvalid(self.imgIcon)) then self.imgIcon:SetPos(5, 5) self.imgIcon:SetSize(16, 16) title_push = 16 end

            self.btnClose:SetPos(self:GetWide() - 24 - 4, 0)     self.btnClose:SetSize(24, 24)
            self.btnMaxim:SetPos(self:GetWide() - 24 * 2 - 4, 0) self.btnMaxim:SetSize(24, 24)
            self.btnMinim:SetPos(self:GetWide() - 24 * 3 - 4, 0) self.btnMinim:SetSize(24, 24)
            self.lblTitle:SetPos(8 + title_push, 2)              self.lblTitle:SetSize(self:GetWide() - 25 - title_push, 20)
        end

        local grad_mat = Material("gui/gradient")
        window.Paint = function(_, w, h)
            surf_set_drawcolor(240, 240, 240)    surf_drawrect(0, 0, w, h)
            surf_set_drawcolor(0, 0, 0)          surf_drawrect_outline(0, 0, w, h, 1.5)
            surf_set_drawcolor(77, 79, 204, 215) surf_drawrect(1, 1, w - 1.5, 23)
            surf_set_drawcolor(77, 79, 204)      surf_setmaterial(grad_mat) surf_drawrect_textured(1, 1, w - 1.5, 23)
        end

        local con = vgui.Create("DPanel", window)
        con:Dock(FILL) con:DockMargin(0, 0, 0, 4)

        con.Paint = function(_, w, h) surf_set_drawcolor(215, 215, 215) surf_drawrect(0, 0, w, h) end

        stdout:SetParent(con) stdout:Dock(FILL) stdout:DockMargin(0, 0, 0, 4) stdout:Show()

        local cmd = vgui.Create("DTextEntry", window)
        cmd:Dock(BOTTOM) cmd:SetHistoryEnabled(true) cmd:SetFont("DefaultFixed") cmd:SetUpdateOnType(true)

        cmd.Paint = function(self, w, h)
            surf_set_drawcolor(225, 225, 225) surf_drawrect(0, 0, w, h)
            surf_set_drawcolor(127, 127, 127) surf_drawrect_outline(0, 0, w, h, 1)
            self:DrawTextEntryText(color_black, self:GetHighlightColor(), self:GetCursorColor())
        end

        local cmds = {
            request   = function(_s)
                if LocalPlayer():IsAdmin() then send_request(str_sub(_s, 9, #_s))
                else stdout_append("access violation: not admin") end
            end,
            showtemp  = function(_s)
                if table.IsEmpty(ctemp) then stdout_append("ctemp empty") return end
                for i, t in pairs(ctemp) do stdout_append(str_fmt("id = %i, path = %s", i, t[2])) end
            end,
            myrealmax = function() stdout_append(realmax_msg_size) end,
            clearcon  = function()   stdout:SetText("") end
        }

        cmd.GetAutoComplete = function(self, _s)
            local sug = {}
            for _c in pairs(cmds) do if str_startswith(_c, _s) then sug[#sug + 1] = _c end end
            return sug
        end

        cmd.OnEnter = function(self, _s)
            stdout_append("<< " .. _s)
            local match = false
            for _c , _f in pairs(cmds) do if str_startswith(_s, _c) then _f(_s) match = true end end
            if not match then stdout_append("syntax error!") else self:AddHistory(_s) end
            self:SetText("")
        end
    end)
else
    local delzma         = util.Decompress
    local str_find       = string.find
    local str_gmatch     = string.gmatch
    local tblib_sort     = table.sort

    local netlib_send    = net.Send
    local netlib_rstring = net.ReadString
    local netlib_rdata   = net.ReadData
    local netlib_rbdata  = function() return net.ReadData(netlib_ruint()) end

    local systime        = SysTime

    local cfile_wbyte    = FindMetaTable("File").WriteByte

    util.AddNetworkString"mdlstream_req"
    util.AddNetworkString"mdlstream_frm" -- or Slice
    util.AddNetworkString"mdlstream_ack" -- Acknowledge

    --- I don't want to go oop here, though it may be more elegant
    local temp = temp or {}

    local queue = queue or {}

    netlib_set_receiver("mdlstream_req", function(_, user)
        if not isvalid(user) then return end

        local _path = netlib_rstring()
        local uid   = netlib_ruint64()
        local size  = tonumber(netlib_rstring())

        if flag_testing then goto no_existence_chk end

        if file.Exists(_path, "GAME") and size == file.Size(_path, "GAME") then
            netlib_start("mdlstream_ack")
            netlib_wuintm(0)
            netlib_wuint64(uid)
            netlib_send(user)

            return
        end

        :: no_existence_chk ::

        local function action()
            netlib_start("mdlstream_ack")

            netlib_wuintm(100)

            temp[uid] = {[1] = {}, [2] = _path, [3] = systime()}

            netlib_wuint64(uid)

            netlib_send(user)
        end

        --- [2]: is this task ran?
        queue[#queue + 1] = {[1] = action, [2] = false, [3] = user, [4] = size, [5] = uid}
    end)

    do local front = nil
        --- Sort based on ping and requested file size(factor weight: decreasing)
        local function cmp(e1, e2)
            if e1[3]:Ping() ~= e2[3]:Ping() then return e1[3]:Ping() < e2[3]:Ping()
            elseif    e1[4] ~= e2[4]        then return e1[4] < e2[4] end
        end

        --- Do we have any ran tasks in queue but not removed?(unfinished)
        -- currently, only allow 1 ran tasks max. otherwise, buffer overflows easily
        local function is_ready()
            for i = 1, #queue do if queue[i][2] == true then return false end end
            return true
        end

        timer.Create("mdlstream_watcher", 1, 0, function()
            if #queue == 0 then return end

            --- It's unnecessary to deal with disconnected players' requests
            for i = 1, #queue, -1 do if not isvalid(queue[i][3]) then tblib_remove(queue, i) end end

            if #queue == 0 then return end

            tblib_sort(queue, cmp)

            front = queue[1]

            if front[2] or not is_ready() then return end

            queue[1][1]()
            queue[1][2] = true
        end)
    end

    --- Instead of putting a file in data/ directly, we may need to put it in gma and ask game to load it
    -- https://github.com/CapsAdmin/pac3/blob/master/lua/pac3/core/shared/util.lua#L145
    -- https://github.com/Facepunch/gmad/blob/master/include/AddonReader.h
    local function wgma(_path, _content, _uid)
        local path_gma = string.gsub(_path, "%/", "//") .. ".gma"
        local _f = file_open(path_gma, "wb", "DATA")
        if not str_startswith(_path, "models/") then _path = "models/" .. _path end

        _f:Write("GMAD") _f:WriteByte(3) -- ver

        _f:WriteUInt64(0) -- steamid(unused)
        _f:WriteUInt64(os.time(os.date("!*t"))) -- timestamp

        _f:WriteByte(0) -- required content(unused)

        _f:Write("mdlstream_gma" .. _uid) _f:WriteByte(0) -- addon name
        _f:Write("")                      _f:WriteByte(0) -- desc
        _f:Write("")                      _f:WriteByte(0) -- author

        _f:WriteULong(1) -- addon ver(unused)

        _f:WriteULong(1) -- filenum, starts from 1
        _f:Write(_path) _f:WriteByte(0)

        _f:WriteUInt64(file.Size(_path, "DATA"))
        _f:WriteULong(tonumber(util.CRC(_path)))

        _f:WriteULong(0) -- indicates end of file(s)

        _f:Write(_content)

        _f:Flush()

        _f:WriteULong(tonumber(util.CRC(file.Read(path_gma, "DATA"))))

        _f:Close()
    end

    --- Serverside decompression
    bs_codec = table.Flip(bs_codec)

    -- TODO: make the pattern more precise
    local function ctb(_s)
        local _bytes = {}

        for token in str_gmatch(_s, "([%~%^]?[^%~%^%s%c])") do
            _bytes[#_bytes + 1] = bs_codec[token]
        end

        return _bytes
    end

    -- @BUFFER_SENSITIVE
    netlib_set_receiver("mdlstream_frm", function(_, user)
        local uid        = netlib_ruint64()
        local frame_type = netlib_ruintm()
        local content    = netlib_rbdata()

        if frame_type == 200 then
            local bytes

            if #temp[uid][1] == 0 then
                bytes = ctb(delzma(content))
            else
                temp[uid][1][#temp[uid][1] + 1] = content

                bytes = ctb(delzma(tblib_concat(temp[uid][1])))
            end

            local path = temp[uid][2]

            if str_startswith(path, "data/") then path = str_sub(path, 6) end

            file.CreateDir(string.GetPathFromFilename(path))

            local _file = file_open(path, "wb", "DATA")

            for i = 1, #bytes do
                cfile_wbyte(_file, bytes[i])
            end

            _file:Close()

            wgma(path, file.Read(path, "DATA"), uid)

            local tlapse = systime() - temp[uid][3]

            print(str_fmt(mstr"took %s recv & build '%s' from %s, avg spd %s/s",
                string.FormattedTime(tlapse, "%02i:%02i:%02i"), path,
                user:SteamID64(), string.NiceSize(file_size(path, "DATA") / tlapse)))

            temp[uid] = nil

            --- Removes completed task from queue
            for i = 1, #queue do if queue[i][5] == uid then tblib_remove(queue, i) break end end

            netlib_start("mdlstream_ack")
            netlib_wuintm(1)
            netlib_wuint64(uid)
        elseif frame_type == 201 then
            temp[uid][1][#temp[uid][1] + 1] = content

            netlib_start("mdlstream_ack")

            netlib_wuintm(101)

            netlib_wuint64(uid)
            netlib_wuint(netlib_ruint())
        end

        netlib_send(user)
    end)
end