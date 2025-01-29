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
local flag_keepobj  = true
local flag_nohdrchk = false

--- Shared konstants(not necessarily)
-- ! Unless otherwise stated, all the numbers related to msg sizes are all in 'bytes'
--
local tonumber   = tonumber
local isvalid    = IsValid
local systime    = SysTime
local math_sqrt  = math.sqrt
local math_pi    = math.pi
local math_max   = math.max
local math_min   = math.min
local math_floor = math.floor

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
--
--  91: Server requests client to send vvd data type sequence
--  92: Client sends vvd data type seq
--  10: Server has received vvd data type seq and awaits data
--  11: Server awaits subsequent vvd data
--  93: similar to 200, but for vvd
--  94: similar to 201, but for vvd
--
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

--- https://www.codeproject.com/Articles/5366994/16bit-Normal-Vectors-Compression-using-Spherical-C
-- Thanks to DeepSeek r1 and me!
local B_THETA, B_PHI = 12, 12
local packed_normal_bits = B_THETA + B_PHI

local function encode_normal(x, y, z)
    local len = math_sqrt(x * x + y * y + z * z) + 1e-7
    x, y, z = x / len, y / len, z / len

    local MAX_THETA = bit.lshift(1, B_THETA) - 1
    local MAX_PHI = bit.lshift(1, B_PHI) - 1

    local quant_theta = math_floor((0.5 - 0.5 * z) * (MAX_THETA + 1) + 0.5)
    quant_theta = math_max(0, math_min(quant_theta, MAX_THETA))

    local phi = math.atan2(y, x)
    phi = (phi < 0) and (phi + 2 * math_pi) or phi
    local quant_phi = math_floor(phi / (2 * math_pi) * (MAX_PHI + 1) + 0.5) % (MAX_PHI + 1)

    return bit.bor(bit.lshift(quant_theta, B_PHI), quant_phi)
end

local function decode_normal(packed)
    local MAX_THETA = bit.lshift(1, B_THETA) - 1
    local MAX_PHI = bit.lshift(1, B_PHI) - 1

    local quant_theta = bit.band(bit.rshift(packed, B_PHI), MAX_THETA)
    local quant_phi = bit.band(packed, MAX_PHI)

    local cos_theta = 1 - (2 * (quant_theta + 0.5)) / (MAX_THETA + 1)
    cos_theta = math_max(-1, math_min(1, cos_theta))
    local phi = (quant_phi + 0.5) * (2 * math_pi) / (MAX_PHI + 1)

    local sin_theta = math_sqrt(1 - cos_theta * cos_theta)

    return sin_theta * math.cos(phi), sin_theta * math.sin(phi), cos_theta
end

if CLIENT then
    local function make_vvd_data_seq(_f)
        local data = {}
        local seq = {}

        -- f: float, l: long, b: byte, s: string, F: 1 or -1 but is float, c: calculated
        local counts = {f = 0, l = 0, b = 0, s = 0, F = 0, c = 0}

        local function reader(type_str, type_char, p1)
            return function()
                data[#data + 1] = _f["Read" .. type_str](_f, p1)
                seq[#seq + 1] = type_char
                counts[type_char] = counts[type_char] + 1
                return data[#data]
            end
        end

        local function read_normal()
            local x0, y0, z0 = _f:ReadFloat(), _f:ReadFloat(), _f:ReadFloat()
            local packed = encode_normal(x0, y0, z0)
            data[#data + 1] = packed seq[#seq + 1] = "c" counts.c = counts.c + 1

            x0, y0, z0 = nil, nil, nil
        end

        local float = reader("Float", "f")
        local float0 = reader("Float", "F")
        local long = reader("Long", "l")
        local byte = reader("Byte", "b")
        local str4 = reader("", "s", 4)

        str4()

        long() long()

        local numlods = long()

        local numlodvertexes0 = long()
        long() long() long() long() long() long() long()

        local numfixups = long()
        local fixuptablestart = long()
        local vertexdatastart = long()
        local tangentdatastart = long()

        if numfixups > 0 then
            _f:Seek(fixuptablestart)

            for _ = 1, numfixups do
                long() long() long()
            end
        end

        if numlods > 0 then
            _f:Seek(vertexdatastart)

            for _ = 1, numlodvertexes0 do
                float() float() float()

                byte() byte() byte()

                byte()

                float() float() float()

                -- normals
                read_normal()

                float() float()
            end
        end

        _f:Seek(tangentdatastart)

        for _ = 1, numlodvertexes0 do
            -- tangents
            read_normal()
            float0()
        end

        return {data, seq, counts}
    end

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

    local mdl_versions = {
        --- Known: 4 is "HLAlpha", 6, 10 is "HLStandardSDK" related
        -- 14 is used in "Half-Life SDK", too old
        -- [2531] = true, [27] = true, [28] = true, [29] = true,
        -- [30]   = true, [31] = true, [32] = true, [35] = true, [36] = true, [37] = true,
        [44] = true, [45] = true, [46] = true, [47] = true, [48] = true, [49] = true,
        [52] = true, [53] = true, [54] = true, [55] = true, [56] = true, [58] = true, [59] = true
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

            if studiohdr_t.id ~= "IDST" then return false end
            if studiohdr_t.length ~= file_size(_path, "GAME") then return false end

            if not mdl_versions[studiohdr_t.version] then return false end
            if studiohdr_t.checksum <= 0 then return false end
            if not studiohdr_t.name then return false end
        elseif _ext == "vvd" then
            local vertexFileHeader_t = {
                id       = _file:Read(4),
                version  = _file:ReadLong(),
                checksum = _file:ReadLong()
            }

            if vertexFileHeader_t.id ~= "IDSV" and vertexFileHeader_t.id ~= "IDCV" then return false end
            if vertexFileHeader_t.version < 4 then return false end
            if vertexFileHeader_t.checksum <= 0 then return false end
        end

        _file:Close()

        return true
    end

    local function uidgen() return string.gsub(tostring(systime()), "%.", "", 1) end

    local ctemp = ctemp or {}

    -- TODO: clientside postpone frame dispatch when ping too high/unstable, and a state machine serverside
    local function send_request(path, callback)
        local ext = str_ext_fromfile(path)
        assert(isstring(path),            mstr"'path' is not a string")
        assert(file.Exists(path, "GAME"), mstr"Desired filepath does not exist on client, " .. path)
        assert(file_formats[ext],         mstr"Tries to send unsupported file, "            .. path)

        local size = file_size(path, "GAME")

        assert(size <= max_file_size, mstr"Tries to send file larger than 8388608 bytes, " .. path)

        if not flag_nohdrchk then
            assert(validate_header(path), mstr"Corrupted or intentionally bad file (header), " .. path)
        end

        if not callback or not isfunction(callback) then callback = fun_donothing end

        local uid = uidgen()

        --- FIXME: actual size reduction needed
        if ext == "vvd" then
            ctemp[uid] = {[1] = make_vvd_data_seq(file.Open(path, "rb", "GAME")), [2] = path, [3] = callback}
        else
            ctemp[uid] = {[1] = util.Base64Encode(lzma(file.Read(path, "GAME")), true), [2] = path, [3] = callback}
        end

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
        elseif ping >= 31  and ping < 50  then realmax_msg_size = max_msg_size - 6000
        elseif ping >= 51  and ping < 100 then realmax_msg_size = max_msg_size - 16000
        elseif ping >= 101 and ping < 200 then realmax_msg_size = max_msg_size - 28000
        else                                   realmax_msg_size = 14000 end
    end

    local function w_framemode(_exceeds) if not _exceeds then netlib_wuintm(200) else netlib_wuintm(201) end end
    local function w_framemode_vvd(_exceeds) if not _exceeds then netlib_wuintm(93) else netlib_wuintm(94) end end

    local writers_vvd_data = {
        f = function(v) net.WriteFloat(v) end,
        l = function(v) net.WriteInt(v, 32) end,
        b = function(v) netlib_wuintm(v) end,
        s = function(v) netlib_wstring(v) end,
        F = function(v) net.WriteBit(v == 1) end,
        c = function(v) net.WriteUInt(v, packed_normal_bits) end
    }
    local sizes = {
        f = 4,
        l = 4,
        b = 1,
        s = 4,
        F = 0.125,
        c = packed_normal_bits / 8
    }

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

        if _mode == 91 then
            netlib_wuintm(92)
            netlib_wbdata(lzma(tblib_concat(ctemp[uid][1][2])), 1)
            netlib_toserver()

            return
        end

        local data = ctemp[uid][1]

        local seq
        if _mode == 10 or _mode == 11 then
            data, seq = ctemp[uid][1][1], ctemp[uid][1][2]
        end

        --- May better simplify section below
        local exceeds_max, pos
        if _mode == 10 then
            local counts = ctemp[uid][1][3]
            local actual_size = counts.f * sizes.f + counts.l * sizes.l + counts.b + counts.s * sizes.s + counts.F * sizes.F

            exceeds_max = actual_size > realmax_msg_size
            w_framemode_vvd(exceeds_max)
            if not exceeds_max then
                netlib_wuint(1)
                for k, v in ipairs(seq) do
                    writers_vvd_data[v](data[k])
                end
            else
                local bytes_written = 0

                for k, v in ipairs(seq) do
                    if bytes_written >= realmax_msg_size - 8 then pos = k break end

                    bytes_written = bytes_written + sizes[v]
                end

                netlib_wuint(1)
                netlib_wuint(pos)

                for k, v in ipairs(seq) do
                    if k == pos then break end
                    writers_vvd_data[v](data[k])
                end
            end
        elseif _mode == 11 then
            pos = netlib_ruint()

            local actual_size = 0
            for i = pos, #seq do
                actual_size = actual_size + sizes[seq[i]]
            end
            exceeds_max = actual_size > realmax_msg_size
            w_framemode_vvd(exceeds_max)
            if not exceeds_max then
                netlib_wuint(pos)
                for i = pos, #seq do
                    writers_vvd_data[seq[i]](data[i])
                end
            else
                local endpos
                local bytes_written = 0
                for i = pos, #seq do
                    if bytes_written >= realmax_msg_size - 8 then endpos = i break end
                    bytes_written = bytes_written + sizes[seq[i]]
                end

                netlib_wuint(pos)
                netlib_wuint(endpos)

                for i = pos, endpos - 1 do
                    writers_vvd_data[seq[i]](data[i])
                end
            end

        elseif _mode == 100 then
            exceeds_max = #data > realmax_msg_size
            w_framemode(exceeds_max)

            if not exceeds_max then
                netlib_wbdata(data, 1, nil)
            else
                netlib_wbdata(data, 1, realmax_msg_size)
                netlib_wuint(realmax_msg_size)
            end
        elseif _mode == 101 then
            pos         = netlib_ruint()
            exceeds_max = #data - pos > realmax_msg_size

            w_framemode(exceeds_max)

            if not exceeds_max then
                netlib_wbdata(data, pos + 1, nil)
            else
                local _endpos = pos + realmax_msg_size

                netlib_wbdata(data, pos + 1, _endpos)
                netlib_wuint(_endpos)
            end
        end

        netlib_toserver()

        local filename = ctemp[uid][2]

        if exceeds_max then
            if _mode == 100 or _mode == 10 then
                stdout:append("starting frame sent: " .. filename, true)
            elseif _mode == 101 or _mode == 11 then
                stdout:append(str_fmt("progress: %s %u%%", filename, math.floor((pos / #data) * 100)), true)
            elseif _mode == 91 then
                stdout:append("type sequence sent: " .. filename, true)
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

        -- TODO: make it more stable
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

    local cfile_wbyte    = FindMetaTable("File").WriteByte

    util.AddNetworkString"mdlstream_req"
    util.AddNetworkString"mdlstream_frm" -- or Slice
    util.AddNetworkString"mdlstream_ack" -- Acknowledge

    --- I don't want to go oop here, though it may be more elegant
    local temp  = temp or {}
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

            if string.GetExtensionFromFilename(_path) == "vvd" then
                netlib_wuintm(91)
            else
                netlib_wuintm(100)
            end

            temp[uid] = {[1] = {}, [2] = _path, [3] = systime()}

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

    local readers_vvd_data = {
        f = function() return net.ReadFloat() end,
        l = function() return net.ReadInt(32) end,
        b = function() return netlib_ruintm() end,
        s = function() return netlib_rstring() end,
        F = function() return net.ReadBit() and 1 or -1 end,
        c = function() return net.ReadUInt(packed_normal_bits) end
    }

    local writers_vvd_data = {
        f = function(_f, v) _f:WriteFloat(v) end,
        l = function(_f, v) _f:WriteLong(v) end,
        b = function(_f, v) _f:WriteByte(v) end,
        s = function(_f, v) _f:Write(v) end,
        F = function(_f, v) if v == 1 then v = 1 else v = -1 end _f:WriteFloat(v) end,
        c = function(_f, v)
            x, y, z = decode_normal(v)
            _f:WriteFloat(x) _f:WriteFloat(y) _f:WriteFloat(z)
        end
    }

    -- TODO: ensure file save failure got dealt with
    -- @BUFFER_SENSITIVE
    netlib_set_receiver("mdlstream_frm", function(_, user)
        local uid        = netlib_ruint64()
        local frame_type = netlib_ruintm()

        local content
        if frame_type ~= 93 and frame_type ~= 94 then
            content = netlib_rbdata()
        end

        -- @EDGE_CASE
        if not temp[uid] then
            netlib_start("mdlstream_ack")
            netlib_wuintm(2)
            netlib_wuint64(uid)
            netlib_send(user)

            return
        end

        local path, path_gma

        if frame_type == 93 or frame_type == 200 then
            path = temp[uid][2]
            if str_startswith(path, "data/") then path = str_sub(path, 6) end
            file.CreateDir(string.GetPathFromFilename(path))
        end

        if frame_type == 92 then
            temp[uid][5] = string.ToTable(delzma(content))

            netlib_start("mdlstream_ack")
            netlib_wuintm(10)
            netlib_wuint64(uid)
        elseif frame_type == 93 then
            local startpos = netlib_ruint()

            for i = startpos, #temp[uid][5] do
                temp[uid][1][#temp[uid][1] + 1] = readers_vvd_data[temp[uid][5][i]]()
            end

            local _file = file_open(path, "wb", "DATA")

            for k, v in ipairs(temp[uid][1]) do
                writers_vvd_data[temp[uid][5][k]](_file, v, temp[uid][1], k)
            end

            _file:Close()
        elseif frame_type == 94 then
            local startpos = netlib_ruint()
            local endpos = netlib_ruint()

            for i = startpos, endpos - 1 do
                temp[uid][1][#temp[uid][1] + 1] = readers_vvd_data[temp[uid][5][i]]()
            end

            netlib_start("mdlstream_ack")
            netlib_wuintm(11)
            netlib_wuint64(uid)
            netlib_wuint(endpos)
        elseif frame_type == 200 then
            local str

            if #temp[uid][1] == 0 then
                str = delzma(util.Base64Decode(content))
            else
                temp[uid][1][#temp[uid][1] + 1] = content

                str = delzma(util.Base64Decode(tblib_concat(temp[uid][1])))
            end

            local _file = file_open(path, "wb", "DATA")
            _file:Write(str)
            _file:Close()
        elseif frame_type == 201 then
            temp[uid][1][#temp[uid][1] + 1] = content

            netlib_start("mdlstream_ack")
            netlib_wuintm(101)
            netlib_wuint64(uid)
            netlib_wuint(netlib_ruint())
        end

        if frame_type == 93 or frame_type == 200 then
            path_gma = string.StripExtension(wgma(path, file.Read(path, "DATA"), uid))

            if not flag_keepobj then file.Delete(path, "DATA") end

            local dt = systime() - temp[uid][3]
            print(
                str_fmt(mstr"took %s recv & build '%s' from %s, avg spd %s/s",
                    string.FormattedTime(dt, "%02i:%02i:%02i"),
                    path,
                    user:SteamID64(),
                    string.NiceSize(
                        file_size(flag_keepobj and path or path_gma .. ".gma", "DATA") / dt
                    )
                )
            )

            temp[uid] = nil

            --- Removes completed task from queue
            for i = 1, #queue do if queue[i][5] == uid then tblib_remove(queue, i) break end end

            netlib_start("mdlstream_ack")
            netlib_wuintm(1)
            netlib_wuint64(uid)
        end

        netlib_send(user)
    end)
end

if not CLIENT then return end

concommand.Add("mdt_normalpack_test", function()
    local function angular_error(orig, dec)
        local dot = orig[1] * dec[1] + orig[2] * dec[2] + orig[3] * dec[3]
        dot = math_max(-1, math_min(1, dot))
        return math.deg(math.acos(dot))
    end

    local normals = {}

    math.randomseed(os.time())

    local function random_normal()
        local u1 = math.random()
        local u2 = math.random()

        local phi = 2 * math_pi * u1
        local theta = math.acos(2 * u2 - 1)

        local sin_theta = math.sin(theta)
        return {
            sin_theta * math.cos(phi),
            sin_theta * math.sin(phi),
            math.cos(theta)
        }
    end

    for i = 1, 100000 do
        normals[i] = random_normal()
    end

    local max_error = 0
    local avg_error = 0

    for i, v in ipairs(normals) do
        local packed = encode_normal(v[1], v[2], v[3])
        local x, y, z = decode_normal(packed)
        local err = angular_error(v, {x, y, z})

        max_error = math.max(max_error, err)
        avg_error = avg_error + err
    end

    avg_error = avg_error / #normals

    print("phi:", B_PHI, "bits:", B_PHI + B_THETA)
    print(string.format("maximum angular error: %.5f°", max_error))
    print(string.format("average angular error: %.5f°", avg_error))
end)