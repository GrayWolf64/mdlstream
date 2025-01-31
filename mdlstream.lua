--- MDLStream
-- Sync necessary files of client models to server so that server can initialize models' physics
-- For use with addons which require clientside model files to be sent to server
--
-- Specifications:
-- Max file size: 8.388608 MB
-- Limited file formats(model related)
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
-- Torture when unearthing mdl structure: https://github.com/RaphaelIT7/sourcesdk-gmod/blob/main/utils/studiomdl/write.cpp
--
if not gmod or game.SinglePlayer() then return end

mdlstream = {}

--- Switches
--
-- `flag_testing`: Disables file existence check serverside
-- `flag_noclui`: Disables clientside debugger GUI; Routes some terminal(debugger ui) messages to engine console
-- `flag_allperm`: Disables permission(admin) check when performing certain non-programmatic actions, like `request`
-- `flag_keepobj`: True to keep original downloaded file, false to only keep encapsulated .gma
-- `flag_nohdrchk`: Disables valve file header check, used for testing with randomly generated file
local flag_testing      = true
local flag_noclui       = false
local flag_allperm      = true
local flag_keepobj      = true
local flag_nohdrchk     = false

--- Shared constants(not necessarily)
-- ! Unless otherwise stated, all the numbers related to msg sizes are all in 'bytes'
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

--- Dedicated to read and write response mode, max = 255
--
-- 0: Server has refused request(file already exists on server)
-- 1: Server has built file and sends an ack for finalization
-- 2: Server has refused request, whose serverside temp isn't allocated properly ahead of time
--
-- 91: Server requests client to send vvd data type sequence
-- 92: Client sends vvd data type seq
-- 10: Server has received vvd data type seq and awaits data
-- 11: Server awaits subsequent vvd data
-- 93: similar to 200, but for vvd
-- 94: similar to 201, but for vvd
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

if CLIENT then
    local function make_vvd_data_seq(_f)
        local data = {}
        local seq = {}

        -- f: float, l: long, k: seek pos, e: section end, b: byte, s: string
        -- F: 1 or -1 but is float, B: MAX_NUM_LODS = 8(lod: 0~7), a 3 bit UInt will do
        -- n: MAX_NUM_BONES_PER_VERT = 3(numbones: 0~3), a 2 bit UInt
        local counts = {f = 0, l = 0, k = 0, e = 0, b = 0, s = 0, F = 0, B = 0, n = 0}

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

            data[#data + 1] = x0 seq[#seq + 1] = "f"
            data[#data + 1] = y0 seq[#seq + 1] = "f"
            data[#data + 1] = z0 seq[#seq + 1] = "f"
            counts.f = counts.f + 3

            x0, y0, z0 = nil, nil, nil
        end

        local function section_end()
            data[#data + 1] = _f:Tell() seq[#seq + 1] = "e"
            counts.e = counts.e + 1
        end

        local float = reader("Float", "f")
        local float0 = reader("Float", "F")
        local long = reader("Long", "l")
        local seekpos = reader("Long", "k")
        local lod = reader("Long", "B")
        local byte = reader("Byte", "b")
        local numbones = reader("Byte", "n")
        local str4 = reader("", "s", 4)

        str4()

        long() long()

        local numlods = long()

        local numlodvertexes0 = long()
        long() long() long() long() long() long() long()

        local numfixups = long()
        local fixuptablestart = seekpos()
        local vertexdatastart = seekpos()
        local tangentdatastart = seekpos()

        if numfixups > 0 then
            _f:Seek(fixuptablestart)

            for _ = 1, numfixups do
                lod() long() long()
            end

            section_end()
        end

        if numlods > 0 then
            _f:Seek(vertexdatastart)

            for _ = 1, numlodvertexes0 do
                float() float() float()

                byte() byte() byte()

                numbones()

                float() float() float()

                -- normals
                read_normal()

                float() float()
            end

            section_end()
        end

        _f:Seek(tangentdatastart)

        for _ = 1, numlodvertexes0 do
            -- tangents
            read_normal() float0()
        end

        return data, seq, counts
    end

    -- FRAME content:
    -- TODO: recalculate distribution
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
        assert(isstring(path), mstr"'path' is not a string")
        assert(file_formats[ext], mstr"Tries to send unsupported file, " .. path)
        assert(file.Exists(path, "GAME"), mstr"Desired filepath does not exist on client, " .. path)

        local size = file_size(path, "GAME")

        assert(size <= max_file_size, mstr"Tries to send file larger than 8388608 bytes, " .. path)

        if not flag_nohdrchk then
            assert(validate_header(path), mstr"Corrupted or intentionally bad file (header), " .. path)
        end

        if not callback or not isfunction(callback) then callback = fun_donothing end

        local uid = uidgen()

        --- FIXME: actual size reduction needed
        if ext == "vvd" then
            ctemp[uid] = {[1] = {make_vvd_data_seq(file.Open(path, "rb", "GAME"))}, [2] = path, [3] = callback}
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
        k = function(v) net.WriteInt(v, 32) end,
        e = function(v) net.WriteInt(v, 32) end,
        b = function(v) netlib_wuintm(v) end,
        s = function(v) netlib_wstring(v) end,
        F = function(v) net.WriteBit(v > 0) end,
        B = function(v) net.WriteUInt(v, 3) end,
        n = function(v) net.WriteUInt(v, 2) end
    }
    local sizes = {
        f = 4,
        l = 4,
        k = 4,
        e = 4,
        b = 1,
        s = 4,
        F = 0.125,
        B = 0.375,
        n = 0.25
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
            local actual_size = counts.f * sizes.f + counts.l * sizes.l
                + counts.k * sizes.k + counts.e * sizes.e + counts.b * sizes.b + counts.s * sizes.s
                + counts.F * sizes.F + counts.B * sizes.B + counts.n * sizes.n

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

    /*
    * Debugger UI
    */
    if flag_noclui then
        stdout.append = function(_s) print(mstr(_s)) end
        stdout:Remove()

        return
    end

    local surf_set_drawcolor, surf_setmaterial, surf_drawrect, surf_drawrect_outline, surf_drawrect_textured
    = surface.SetDrawColor, surface.SetMaterial, surface.DrawRect, surface.DrawOutlinedRect, surface.DrawTexturedRect

    concommand.Add("mdt", function()
        if stdout:GetText() == "" then
            stdout:append("MDLStream (Simple) Debugger - Licensed under Apache License 2.0\n", true)
        end

        local window = vgui.Create("DFrame")
        window:Center() window:SetSize(ScrW() / 2, ScrH() / 2.8)
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

        local cmds = {
            request = function(args)
                if LocalPlayer():IsAdmin() or flag_allperm then
                    send_request(args)
                else
                    stdout:append("access violation: not admin", true)
                end
            end,

            showtemp = function()
                if table.IsEmpty(ctemp) then
                    stdout:append("ctemp empty", true)
                    return
                end
                for i, t in ipairs(ctemp) do
                    stdout:append(string.format("id = %i, path = %s", i, t[2]), true)
                end
            end,

            myrealmax = function()
                stdout:append(realmax_msg_size, true)
            end,

            clearcon = function()
                stdout:SetText("")
            end
        }

        cmd.GetAutoComplete = function(_, partial)
            local suggestions = {}
            for cmdName in pairs(cmds) do
                if string.StartWith(cmdName, partial) then
                    table.insert(suggestions, cmdName)
                end
            end
            return suggestions
        end

        cmd.OnEnter = function(self, input)
            stdout:append("< " .. input)

            local command, args = string.match(input, "^%s*(%S+)%s*(.-)%s*$")

            if command and cmds[command] then
                cmds[command](args)
                self:AddHistory(input)
            else
                stdout:append("syntax error: unknown command", true)
            end

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
        k = function() return net.ReadInt(32) end,
        e = function() return net.ReadInt(32) end,
        b = function() return netlib_ruintm() end,
        s = function() return netlib_rstring() end,
        F = function() return net.ReadBit() end,
        B = function() return net.ReadUInt(3) end,
        n = function() return net.ReadUInt(2) end
    }

    local writers_vvd_data = {
        f = function(_f, v) _f:WriteFloat(v) end,
        l = function(_f, v) _f:WriteLong(v) end,
        k = function(_f, v) _f:WriteLong(v) end,
        e = function() end,
        b = function(_f, v) _f:WriteByte(v) end,
        s = function(_f, v) _f:Write(v) end,
        F = function(_f, v) if v == 1 then v = 1.0 else v = -1.0 end _f:WriteFloat(v) end,
        B = function(_f, v) _f:WriteLong(v) end,
        n = function(_f, v) _f:WriteByte(v) end
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

            local sectionstart_pos = {}
            local sectionend_count = 0
            for k, v in ipairs(temp[uid][5]) do
                if v == "k" then
                    sectionstart_pos[#sectionstart_pos + 1] = temp[uid][1][k]
                elseif v == "e" then
                    sectionend_count = sectionend_count + 1

                    _file:Seek(sectionstart_pos[sectionend_count + 1])
                end

                writers_vvd_data[v](_file, temp[uid][1][k])
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
                str_fmt(mstr"took %.1f sec recv & build '%s' from %s, avg spd %s/s",
                    dt,
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