--- MDLStream
-- Sync necessary files of client models to server so that server can initialize models' physics
-- For use with addons which require clientside model files to be sent to server
--
-- Specifications:
-- Max file size: 8.75 MB
-- Limited file formats
-- Handshake styled transmission
--
-- ! If you are server owner, I suggest you using https://github.com/WilliamVenner/gmsv_workshop/ for better experience
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
-- Thanks to: https://github.com/ZeqMacaw/Crowbar/tree/master/Crowbar/Core/GameModel for some crucial hints on mdl header1
-- Torture when unearthing a mdl structure: https://github.com/RaphaelIT7/sourcesdk-gmod/blob/main/utils/studiomdl/write.cpp
--
if not gmod or game.SinglePlayer() then return end

mdlstream = {}

---
--* Switches
--
-- `flag_testing`:  Disables file existence check serverside
-- `flag_noclui`:   Disables clientside debugger GUI; Routes some terminal(debugger ui) messages to engine console
-- `flag_allperm`:  Disables permission(admin) check when performing certain non-programmatic actions, like `request`
-- `flag_keepobj`:  True to keep original downloaded file, false to only keep encapsulated .gma
-- `flag_nohdrchk`: Disables valve file header check, used for testing with randomly generated file
local flag_testing  = true
local flag_noclui   = false
local flag_allperm  = true
local flag_keepobj  = false
local flag_nohdrchk = false

--- Shared konstants(not necessarily)
-- ! Unless otherwise stated, all the numbers related to msg sizes are all in 'bytes'
--
local tonumber            = tonumber
local isvalid             = IsValid
local systime             = SysTime

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
--   2: Server has refused request, whose serverside temp isn't allocated properly ahead of time
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
local tblib_sort          = table.sort

local file_size           = file.Size

local mstr                = function(_s) return "MDLStream: " .. _s end

local str_startswith      = function(_s, start) return str_sub(_s, 1, #start) == start end

local file_open           = function(_f, _m, _p)
    local __f = file.Open(_f, _m, _p) if not __f then error("file descriptor invalid", 2) end
    return __f
end

if CLIENT then
    -- FRAME content:
    -- 3 spared for engine use
    -- 1 for determining the response mode
    -- #content for the actual partial(sliced) compressed string of byte sequence of target file
    -- 3 for #content(slice / frame) length
    -- 3 for #content frame ending position
    -- 8 for uid(int64:str) of every accepted request, generated on client
    -- some bytes spared for testing the most optimal size
    local max_msg_size     = 65536 - 3 - 1 - 3 - 3 - 8 - 10518

    local lzma             = util.Compress

    local netlib_wstring   = net.WriteString
    local netlib_toserver  = net.SendToServer

    local cfile_eof        = FindMetaTable("File").EndOfFile
    local cfile_rbyte      = FindMetaTable("File").ReadByte

    local str_ext_fromfile = string.GetExtensionFromFilename

    local util_t2json      = util.TableToJSON

    local fun_donothing    = function() end

    local realmax_msg_size = max_msg_size

    local max_file_size    = 8 * 1024 * 1024

    local file_formats     = {mdl = true, phy = true, vvd = true, ani = true, vtx = true}

    local function netlib_wbdata(_bs, _start, _end)
        local _size = #_bs
        if not _end then _end = _size end
        size = _end - _start + 1
        netlib_wuint(size)
        net.WriteData(str_sub(_bs, _start, _end), size)
    end

    --- All the codes to represent a byte
    -- "~", "^" for extension of representable range
    local bs_codec = {
        [1]  = "a", [2]  = "b", [3]  = "c", [4]  = "d", [5]  = "e", [6]  = "f", [7]  = "g", [8]  = "h",
        [9]  = "i", [10] = "j", [11] = "k", [12] = "l", [13] = "m", [14] = "n", [15] = "o", [16] = "p",
        [17] = "q", [18] = "r", [19] = "s", [20] = "t", [21] = "u", [22] = "v", [23] = "w", [24] = "x",
        [25] = "y", [26] = "z",

        [27] = "A", [28] = "B", [29] = "C", [30] = "D", [31] = "E", [32] = "F", [33] = "G", [34] = "H",
        [35] = "I", [36] = "J", [37] = "K", [38] = "L", [39] = "M", [40] = "N", [41] = "O", [42] = "P",
        [43] = "Q", [44] = "R", [45] = "S", [46] = "T", [47] = "U", [48] = "V", [49] = "W", [50] = "X",
        [51] = "Y", [52] = "Z",

        [53] = "0", [54] = "1", [55] = "2", [56] = "3", [57] = "4",
        [58] = "5", [59] = "6", [60] = "7", [61] = "8", [62] = "9",

        [63] = "!", [64] = "\"", [65] = "#", [66] = "$", [67] = "%", [68] = "&", [69] = "'", [70] = "(",
        [71] = ")", [72] = "*",  [73] = "+", [74] = ",", [75] = "-", [76] = ".", [77] = "/", [78] = ":",
        [79] = ";", [80] = "<",  [81] = "=", [82] = ">", [83] = "?", [84] = "@", [85] = "[", [86] = "\\",
        [87] = "]", [88] = "_",  [89] = "`", [90] = "{", [91] = "|", [92] = "}",


        [93]  = "~a", [94]  = "~b", [95]  = "~c", [96]  = "~d", [97]  = "~e", [98]  = "~f", [99]  = "~g",
        [100] = "~h", [101] = "~i", [102] = "~j", [103] = "~k", [104] = "~l", [105] = "~m", [106] = "~n",
        [107] = "~o", [108] = "~p", [109] = "~q", [110] = "~r", [111] = "~s", [112] = "~t", [113] = "~u",
        [114] = "~v", [115] = "~w", [116] = "~x", [117] = "~y", [118] = "~z",

        [119] = "~A", [120] = "~B", [121] = "~C", [122] = "~D", [123] = "~E", [124] = "~F", [125] = "~G",
        [126] = "~H", [127] = "~I", [128] = "~J", [129] = "~K", [130] = "~L", [131] = "~M", [132] = "~N",
        [133] = "~O", [134] = "~P", [135] = "~Q", [136] = "~R", [137] = "~S", [138] = "~T", [139] = "~U",
        [140] = "~V", [141] = "~W", [142] = "~X", [143] = "~Y", [144] = "~Z",

        [145] = "~0", [146] = "~1", [147] = "~2", [148] = "~3", [149] = "~4",
        [150] = "~5", [151] = "~6", [152] = "~7", [153] = "~8", [154] = "~9",

        [155] = "~!", [156] = "~\"", [157] = "~#", [158] = "~$", [159] = "~%", [160] = "~&", [161] = "~'",
        [162] = "~(", [163] = "~)",  [164] = "~*", [165] = "~+", [166] = "~,", [167] = "~-", [168] = "~.",
        [169] = "~/", [170] = "~:",  [171] = "~;", [172] = "~<", [173] = "~=", [174] = "~>",


        [175] = "^a", [176] = "^b", [177] = "^c", [178] = "^d", [179] = "^e", [180] = "^f", [181] = "^g",
        [182] = "^h", [183] = "^i", [184] = "^j", [185] = "^k", [186] = "^l", [187] = "^m", [188] = "^n",
        [189] = "^o", [190] = "^p", [191] = "^q", [192] = "^r", [193] = "^s", [194] = "^t", [195] = "^u",
        [196] = "^v", [197] = "^w", [198] = "^x", [199] = "^y", [200] = "^z",

        [201] = "^A", [202] = "^B", [203] = "^C", [204] = "^D", [205] = "^E", [206] = "^F", [207] = "^G",
        [208] = "^H", [209] = "^I", [210] = "^J", [211] = "^K", [212] = "^L", [213] = "^M", [214] = "^N",
        [215] = "^O", [216] = "^P", [217] = "^Q", [218] = "^R", [219] = "^S", [220] = "^T", [221] = "^U",
        [222] = "^V", [223] = "^W", [224] = "^X", [225] = "^Y", [226] = "^Z",

        [227] = "^0", [228] = "^1", [229] = "^2", [230] = "^3", [231] = "^4",
        [232] = "^5", [233] = "^6", [234] = "^7", [235] = "^8", [236] = "^9",

        [237] = "^!", [238] = "^\"", [239] = "^#", [240] = "^$", [241] = "^%", [242] = "^&", [243] = "^'",
        [244] = "^(", [245] = "^)",  [246] = "^*", [247] = "^+", [248] = "^,", [249] = "^-", [250] = "^.",
        [251] = "^/", [252] = "^:",  [253] = "^;", [254] = "^<", [255] = "^=", [256] = "^>"
    }

    local stdout = stdout or vgui.Create("RichText") stdout:Hide()
    stdout.PerformLayout = function(self) self:SetFontInternal("DebugFixed") end
    stdout.change_color = function(self, r, g, b, a) self:InsertColorChange(r, g, b, a) return self end
    stdout.append = function(self, _s, no_info)
        if no_info then goto plain end

        self:change_color(0,   0,   0, 230):AppendText("[")
        self:change_color(0, 197, 205, 255):AppendText(Either(LocalPlayer():IsAdmin(), "admin", "user"))
        self:change_color(0,   0,   0, 230):AppendText("@")
        self:change_color(0, 205,  50, 250):AppendText((game.GetIPAddress()):gsub("loopback", "localhost"))
        self:change_color(0,   0,   0, 230):AppendText("]")
        self:AppendText(" ")

        :: plain ::
        self:change_color(0, 0, 0, 225):AppendText(_s .. "\n")
    end

    local function rhdr_mdl_simple(_file)
        local _h = {}

        _h.id       = _file:Read(4)
        _h.version  = _file:ReadLong()
        _h.checksum = _file:ReadLong()
        _h.name     = _file:Read(64)
        _h.length   = _file:ReadLong()

        return _h
    end

    local function rhdr_vvd_simple(_file)
        local _h = {}

        _h.id               = _file:Read(4)
        _h.version          = _file:ReadLong()
        _h.checksum         = _file:ReadLong()

        return _h
    end

    local mdl_versions = {
        --- Known: 4 is "HLAlpha", 6, 10 is "HLStandardSDK" related
        -- 14 is used in "Half-Life SDK", too old
        -- [2531] = true, [27] = true, [28] = true, [29] = true,
        -- [30]   = true, [31] = true, [32] = true, [35] = true, [36] = true, [37] = true,
        [44]   = true, [45] = true, [46] = true, [47] = true, [48] = true, [49] = true,
        [52]   = true, [53] = true, [54] = true, [55] = true, [56] = true, [58] = true, [59] = true
    }

    --- https://github.com/Tieske/pe-parser/blob/master/src/pe-parser.lua
    -- TODO: Currently, only mdl, vvd header check is implemented
    local function validate_header(_path)
        local _file = file_open(_path, "rb", "GAME")

        if _file:Read(2) == "MZ" then
            _file:Close()

            return false
        end

        _file:Skip(-2)

        local _ext = str_ext_fromfile(_path)
        if _ext == "mdl" then
            local studiohdr_t = rhdr_mdl_simple(_file)

            if studiohdr_t.id     ~= "IDST" then return false end
            if studiohdr_t.length ~= file_size(_path, "GAME") then return false end

            if not mdl_versions[studiohdr_t.version] then return false end
            if studiohdr_t.checksum <= 0 then return false end
            if not studiohdr_t.name then return false end
        elseif _ext == "vvd" then
            local vertexFileHeader_t = rhdr_vvd_simple(_file)

            if vertexFileHeader_t.id ~= "IDSV" and vertexFileHeader_t.id ~= "IDCV" then return false end
            if vertexFileHeader_t.version < 4 then return false end
            if vertexFileHeader_t.checksum <= 0 then return false end
        end

        _file:Close()

        return true
    end

    local function align(offset, _a)
        return math.floor((offset + _a - 1) / _a) * _a
    end

    -- https://github.com/RaphaelIT7/sourcesdk-gmod/blob/313ac36bded1d9ae1b74fcbdf0f5d780c3b6fabc/utils/studiomdl/write.cpp#L67
    local max_num_lods = 8
    local max_num_bones_per_vert = 3
    local function serialize_vvd(_f)
        local data = {}
        local t = ""

        data = table.Merge(data, rhdr_vvd_simple(_f))

        data.numlods = _f:ReadLong()

        data.numlodvertexes = {}
        for i = 1, max_num_lods do
            data.numlodvertexes[i] = _f:ReadLong()
        end

        data.numfixups        = _f:ReadLong()
        data.fixuptablestart  = _f:ReadLong()
        data.vertexdatastart  = _f:ReadLong()
        data.tangentdatastart = _f:ReadLong()

        if data.numfixups > 0 then
            _f:Seek(data.fixuptablestart)

            data.fixups = {}

            for i = 1, data.numfixups do
                data.fixups[i] = {
                    lodindex = _f:ReadLong(),
                    vertexindex = _f:ReadLong(),
                    numvertexes = _f:ReadLong()
                }
            end
        end

        -- https://github.com/RaphaelIT7/sourcesdk-gmod/blob/313ac36bded1d9ae1b74fcbdf0f5d780c3b6fabc/utils/studiomdl/write.cpp#L1821
        if data.numlods > 0 then
            _f:Seek(data.vertexdatastart)

            local boneweight
            local pos
            local normal
            local texcoord
            for i = 1, data.numlodvertexes[1] do
                boneweight = {weight = {}, bone = {}}

                for j = 1, max_num_bones_per_vert do
                    boneweight.weight[j] = _f:ReadFloat()
                end

                for j = 1, max_num_bones_per_vert do
                    boneweight.bone[j] = _f:ReadByte()
                end

                boneweight.numbones = _f:ReadByte()

                pos      = {_f:ReadFloat(), _f:ReadFloat(), _f:ReadFloat()}
                normal   = {_f:ReadFloat(), _f:ReadFloat(), _f:ReadFloat()}
                texcoord = {_f:ReadFloat(), _f:ReadFloat()}
            end

            _f:Seek(data.tangentdatastart)

            local tangent
            for i = 1, data.numlodvertexes[1] do
                tangent = {_f:ReadFloat(), _f:ReadFloat(), _f:ReadFloat(), _f:ReadFloat()}
            end
        end

        return data
    end

    serialize_vvd(file_open("models/player/alyx.vvd", "rb", "GAME"))

    local function bytes_table(_path)
        local bt = {}

        local _file = file_open(_path, "rb", "GAME")

        for i = 1, math.huge do
            if cfile_eof(_file) then break end

            bt[i] = cfile_rbyte(_file)
        end

        _file:Close()

        return bt
    end

    local function optimal_map(_bytes)
        local freq = {}
        for i = 0, 255 do freq[i] = 0 end

        local byte
        for i = 1, #_bytes do
            byte = _bytes[i]
            freq[byte] = freq[byte] + 1
        end

        local sortable = {}

        for i = 0, 255 do
            sortable[i + 1] = {[1] = i, [2] = freq[i]}
        end

        tblib_sort(sortable, function(e1, e2) return e1[2] > e2[2] end)

        local map = {}
        for i = 1, 256 do
            map[sortable[i][1]] = bs_codec[i]
        end

        return map
    end

    local function encode(_map, _bt)
        local chars = {}
        local byte

        for i = 1, #_bt do
            byte = _bt[i]
            chars[#chars + 1] = _map[byte]
        end

        local res = lzma(tblib_concat(chars))
        if flag_testing then stdout:append(str_fmt("encoded len: %i", #res), true) end

        return res
    end

    local function uidgen() return string.gsub(tostring(systime()), "%.", "", 1) end

    local ctemp = ctemp or {}

    -- TODO: clientside postpone frame dispatch when ping too high/unstable, and a state machine serverside
    local function send_request(path, callback)
        assert(isstring(path),                       mstr"'path' is not a string")
        assert(file.Exists(path, "GAME"),            mstr"Desired filepath does not exist on client, " .. path)
        assert(file_formats[str_ext_fromfile(path)], mstr"Tries to send unsupported file, "            .. path)

        local size = file_size(path, "GAME")

        assert(size <= max_file_size, mstr"Tries to send file larger than 8388608 bytes, " .. path)

        if not flag_nohdrchk then
            assert(validate_header(path), mstr"Corrupted or intentionally bad file (header), " .. path)
        end

        if not callback or not isfunction(callback) then callback = fun_donothing end

        local uid = uidgen()

        local bytes = bytes_table(path)
        local map   = optimal_map(bytes)

        --- FIXME: actual size reduction needed
        -- e.g. alyx.mdl #
        -- file.Read + lzma:                                 292884, should just use this?
        -- file.ReadByte + bytes_table + optimal_map + lzma: 340967 (now using)
        -- file.ReadByte + bytes_table + bs_codec + lzma:    334957, shorter than optimal???

        ctemp[uid] = {[1] = encode(map, bytes), [2] = path, [3] = callback}

        netlib_start("mdlstream_req")
        netlib_wstring(path)
        netlib_wuint64(uid)
        netlib_wstring(tostring(size))
        netlib_wbdata(lzma(util_t2json(map)), 1)
        netlib_toserver()
    end

    --- Based on assumptions
    -- we'd better hope that this client's net condition will get better,
    -- otherwise, he will probably wait forever or quit and get some better gear
    local function adjust_max_msg_size()
        if not LocalPlayer() then return end

        local ping = LocalPlayer():Ping()

        if     ping <= 30                 then realmax_msg_size = max_msg_size
        elseif ping >= 31  and ping < 50  then realmax_msg_size = max_msg_size - 6000
        elseif ping >= 51  and ping < 100 then realmax_msg_size = max_msg_size - 16000
        elseif ping >= 101 and ping < 200 then realmax_msg_size = max_msg_size - 28000
        else                                   realmax_msg_size = 14000 end
    end

    local function w_framemode(_exceeds) if not _exceeds then netlib_wuintm(200) else netlib_wuintm(201) end end

    -- @BUFFER_SENSITIVE
    netlib_set_receiver("mdlstream_ack", function()
        local _mode    = netlib_ruintm()
        local uid      = netlib_ruint64()

        if _mode == 0 then
            stdout:append(str_fmt("request rejected(identically sized & named file found: %s)", ctemp[uid][2]), true)
            ctemp[uid] = nil

            return
        elseif _mode == 1 then
            local is_ok = pcall(ctemp[uid][3])

            stdout:append(str_fmt("request finished: %s, callback is_ok = %s", ctemp[uid][2], tostring(is_ok)), true)

            ctemp[uid] = nil

            return
        elseif _mode == 2 then
            -- this may indicate the 'request' was not 'requested' in the form of a `req`, but a straight `frm`
            stdout:append("request rejected(serverside temp not properly allocated)", true)

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
                stdout:append("starting frame sent: " .. filename, true)
            elseif _mode == 101 then
                stdout:append(str_fmt("progress: %s %u%%", filename, math.floor((pos / #_bs) * 100)), true)
            end
        else
            if _mode == 100 or _mode == 101 then stdout:append("last frame sent: " .. filename, true) end
        end
    end)

    mdlstream.SendRequest = send_request

    ---
    --* Debugger part
    --
    if flag_noclui then
        stdout.append = function(_s) print(mstr(_s)) end
        stdout:Remove()

        return
    end

local logo_ascii
= [[
M     M DDDDDD  L        SSSSS
MM   MM D     D L       S     S TTTTT RRRRR  EEEEEE   AA   M    M
M M M M D     D L       S         T   R    R E       A  A  MM  MM
M  M  M D     D L        SSSSS    T   R    R EEEEE  A    A M MM M
M     M D     D L             S   T   RRRRR  E      AAAAAA M    M
M     M D     D L       S     S   T   R   R  E      A    A M    M
M     M DDDDDD  LLLLLLL  SSSSS    T   R    R EEEEEE A    A M    M

MDLStream (Simple) Debugger - Licensed under Apache License 2.0
]]

    local surf_set_drawcolor, surf_setmaterial, surf_drawrect, surf_drawrect_outline, surf_drawrect_textured
    = surface.SetDrawColor, surface.SetMaterial, surface.DrawRect, surface.DrawOutlinedRect, surface.DrawTexturedRect

    concommand.Add("mdt", function()
        if stdout:GetText() == "" then stdout:append(logo_ascii, true) end

        local window = vgui.Create("DFrame")
        window:Center() window:SetSize(ScrW() / 2, ScrH() / 2.5)
        window:SetTitle("MDLStream Debugging Tool") window:MakePopup() window:SetDeleteOnClose(false)

        window.lblTitle:SetFont("BudgetLabel")

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

        -- TODO: use regex to parse
        local cmds = {
            request   = function(_s)
                if LocalPlayer():IsAdmin() or flag_allperm then
                    send_request(str_sub(_s, 9, #_s))
                else
                    stdout:append("access violation: not admin", true)
                end
            end,
            showtemp  = function(_s)
                if table.IsEmpty(ctemp) then stdout:append("ctemp empty", true) return end
                for i, t in pairs(ctemp) do stdout:append(str_fmt("id = %i, path = %s", i, t[2]), true) end
            end,
            myrealmax = function() stdout:append(realmax_msg_size, true) end,
            clearcon  = function() stdout:SetText("") end
        }

        cmd.GetAutoComplete = function(_, _s)
            local t = {}
            for _c in pairs(cmds) do if str_startswith(_c, _s) then t[#t + 1] = _c end end
            return t
        end

        cmd.OnEnter = function(self, _s)
            stdout:append("< " .. _s)
            local match = false
            for _c , _f in pairs(cmds) do if str_startswith(_s, _c) then _f(_s) match = true end end
            if not match then stdout:append("syntax error!", true) else self:AddHistory(_s) end
            self:SetText("")
        end
    end)
else
    -- consider ping difference if greater than this when sorting
    local signifi_pingdiff = 20

    local delzma         = util.Decompress
    local str_find       = string.find
    local str_gmatch     = string.gmatch

    local netlib_send    = net.Send
    local netlib_rstring = net.ReadString
    local netlib_rdata   = net.ReadData
    local netlib_rbdata  = function() return net.ReadData(netlib_ruint()) end

    local util_json2t    = util.JSONToTable

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
        local map   = table.Flip(util_json2t(delzma(netlib_rbdata())))

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

            temp[uid] = {[1] = {}, [2] = _path, [3] = systime(), [4] = map}

            netlib_wuint64(uid)

            netlib_send(user)
        end

        --- [2]: is this task ran?
        queue[#queue + 1] = {[1] = action, [2] = false, [3] = user, [4] = size, [5] = uid}
    end)

    do local front, abs = nil, math.abs
        --- Sort based on ping and requested file size
        local function cmp(e1, e2)
            if abs(e1[3]:Ping() - e2[3]:Ping()) > signifi_pingdiff then return e1[3]:Ping() < e2[3]:Ping()
            elseif e1[4] ~= e2[4] then return e1[4] < e2[4] end
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
            for i = 1, #queue, -1 do
                if not isvalid(queue[i][3]) then tblib_remove(queue, i) end
            end

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
        local path_gma = string.gsub(_path, "%/", ".") .. ".gma"
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

        return path_gma
    end

    local function ctb(_s, _map)
        local _bytes = {}

        for token in str_gmatch(_s, "([%~%^]?[^%~%^%s%c%z])") do
            _bytes[#_bytes + 1] = _map[token]
        end

        return _bytes
    end

    -- TODO: ensure file save failure got dealt with
    -- @BUFFER_SENSITIVE
    netlib_set_receiver("mdlstream_frm", function(_, user)
        local uid        = netlib_ruint64()
        local frame_type = netlib_ruintm()
        local content    = netlib_rbdata()

        -- @EDGE_CASE
        if not temp[uid] then
            netlib_start("mdlstream_ack")
            netlib_wuintm(2)
            netlib_wuint64(uid)
            netlib_send(user)

            return
        end

        -- time of last reply from client
        -- TODO: make use of this
        temp[uid][5] = systime()

        if frame_type == 200 then
            local bytes

            if #temp[uid][1] == 0 then
                bytes = ctb(delzma(content), temp[uid][4])
            else
                temp[uid][1][#temp[uid][1] + 1] = content

                bytes = ctb(delzma(tblib_concat(temp[uid][1])), temp[uid][4])
            end

            local path = temp[uid][2]

            if str_startswith(path, "data/") then path = str_sub(path, 6) end

            file.CreateDir(string.GetPathFromFilename(path))

            local _file = file_open(path, "wb", "DATA")

            for i = 1, #bytes do
                cfile_wbyte(_file, bytes[i])
            end

            _file:Close()

            local _path_gma = string.StripExtension(wgma(path, file.Read(path, "DATA"), uid))

            if not flag_keepobj then file.Delete(path, "DATA") end

            local dt = systime() - temp[uid][3]

            print(str_fmt(mstr"took %s recv & build '%s' from %s, avg spd %s/s",
                string.FormattedTime(dt, "%02i:%02i:%02i"), path,
                user:SteamID64(), string.NiceSize(file_size(_path_gma .. Either(flag_keepobj, "", ".gma"), "DATA") / dt)))

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

--- Test field(one player, local server)
--
-- TODO: optimize size of vvd to be sent
--
-- randomly generated text file with certain size(optimizations can't be applied to it other than lzma)
-- 01:16:94 '8MiB.mdl', avg spd 109.02 KB/s, 2024/11/10