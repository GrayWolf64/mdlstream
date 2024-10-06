--- MDLStream
-- Sync necessary files of client models to server so that server can initialize models' physics
-- For use with cloud asset related addons
-- Specifications:
-- Max file size: 8.75 MB
-- Limited file formats
-- Handshake styled transmission
--
-- !If you are server owner, I suggest you using https://github.com/WilliamVenner/gmsv_workshop/ for better experience
--
-- Possible Workflow: Client Request ==> Server receives Request ==> Server Blinks(acknowledge) ==> Client receives Blink
-- ==> Client sends frame ==> Server receives frame ==> Server builds file(transmisson finished) / Server Blinks
-- ==> Client receives Blink ==> Client sends frame ==> ... Until all frames of file content are fully received, then build(transmisson finished)
--
-- @author GrayWolf, RiceMCUT, Wolf109909
-- @license Apache License 2.0
--
-- More on MDL: https://developer.valvesoftware.com/wiki/MDL_(Source)
-- Thanks to https://github.com/ZeqMacaw/Crowbar/tree/master/Crowbar/Core/GameModel
-- for some crucial hints on mdl header1
if not gmod or game.SinglePlayer() then return end

mdlstream = {}

---
--* Switches
--
local flag_testing = false

--- Shared konstants(not necessarily)
-- !Without extra indication, all the numbers related to msg sizes are all in 'bytes'
local max_msg_size        = 65536 - 3 - 1 - 3 - 3 - 8 - 11000
-- 3 spared for engine use
-- 1 for determining the response mode
-- #content for the actual partial(sliced) compressed string of byte sequence of target file
-- 3 for #content(slice / frame) length
-- 3 for #content frame ending position
-- 8 for uid(int64:str) of every accepted request, generated on client
-- 11000 spared for testing the most optimal size

local tonumber            = tonumber

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
local tblib_concat        = table.concat
local tblib_remove        = table.remove

local str_fmt             = string.format

local file_size           = file.Size

local mstr                = function(_s) return "MDLStream: " .. _s end

local str_startswith      = function(_s, start) return str_sub(_s, 1, #start) == start end

local file_open           = function(_f, _m, _p) local __f = file.Open(_f, _m, _p) if not __f then error("file descriptor invalid", 2) end return __f end

if CLIENT then
    local lzma             = util.Compress

    local netlib_wstring   = net.WriteString
    local netlib_toserver  = net.SendToServer

    local cfile_eof        = FindMetaTable("File").EndOfFile
    local cfile_rbyte      = FindMetaTable("File").ReadByte

    local str_ext_fromfile = string.GetExtensionFromFilename

    local fun_donothing    = function() end

    local realmax_msg_size = max_msg_size

    local max_file_size    = 8750000

    -- VALIDATE ME: does server really need some of them?
    local file_formats     = {mdl = true, phy = true, vvd = true, ani = true, vtx = true}

    local function netlib_wbdata(_data) local _len = #_data netlib_wuint(_len) net.WriteData(_data, _len) end

    local stdout = vgui.Create("RichText") stdout:Hide()

    local function stdout_append(_s)
        stdout:InsertColorChange(0, 205, 50, 255) stdout:AppendText(os.date("%H:%M:%S") .. " ")
        stdout:InsertColorChange(0, 0, 0, 225)    stdout:AppendText(_s .. "\n")
    end

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

    local function bytes_table(_path)
        local _file = file_open(_path, "rb", "GAME")

        local bytes = {}

        for i = 1, math.huge do
            if cfile_eof(_file) then break end

            bytes[i] = cfile_rbyte(_file)
        end

        _file:Close()

        return bytes
    end

    local ctemp = ctemp or {}

    local function uidgen() return string.gsub(tostring(SysTime()), "%.", "", 1) end

    local function send_request(path, callback)
        assert(isstring(path),                       mstr"'path' is not a string")
        assert(file.Exists(path, "GAME"),            mstr"desired 'filepath' does not exist on client, " .. path)
        assert(file_formats[str_ext_fromfile(path)], mstr"Tries to send unsupported file, "              .. path)

        local size = file_size(path, "GAME")

        assert(size <= max_file_size, mstr"Tries to send file larger than 8.75 MB, "       .. path)
        assert(validate_header(path), mstr"Corrupted or intentionally bad file (header), " .. path)

        if not callback or not isfunction(callback) then callback = fun_donothing end

        local uid = uidgen()

        ctemp[uid] = {[1] = lzma(tblib_concat(bytes_table(path), ",")), [2] = path, [3] = callback}

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
        else                                   realmax_msg_size = 24000 end
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

        local _content = ctemp[uid][1]

        --- May better simplify section below
        local exceeds_max, pos
        if _mode == 100 then
            exceeds_max = #_content > realmax_msg_size
            w_framemode(exceeds_max)

            if not exceeds_max then
                netlib_wbdata(_content)
            else
                netlib_wbdata(str_sub(_content, 1, realmax_msg_size))
                netlib_wuint(realmax_msg_size)
            end
        elseif _mode == 101 then
            pos         = netlib_ruint()
            exceeds_max = #_content - pos > realmax_msg_size

            w_framemode(exceeds_max)

            if not exceeds_max then
                netlib_wbdata(str_sub(_content, pos + 1, #_content))
            else
                local _endpos = pos + realmax_msg_size

                netlib_wbdata(str_sub(_content, pos + 1, _endpos))
                netlib_wuint(_endpos)
            end
        end

        netlib_toserver()

        local filename = ctemp[uid][2]

        if exceeds_max then
            if _mode == 100 then
                stdout_append("starting frame sent: " .. filename)
            elseif _mode == 101 then
                stdout_append(str_fmt("progress: %s %u%%", filename, math.floor((pos / #_content) * 100)))
            end
        else
            if _mode == 100 or _mode == 101 then stdout_append("last frame sent: " .. filename) end
        end
    end)

    mdlstream.SendRequest = send_request

    ---
    --* Debugger part
    --
    concommand.Add("mdt", function()
        local window = vgui.Create("DFrame")
        window:Center() window:SetSize(ScrW() / 2, ScrH() / 2.5)
        window:SetTitle("MDLStream Debugging Tool") window:MakePopup() window:SetDeleteOnClose(false)

        window.lblTitle:SetFont("BudgetLabel")

        window.PerformLayout = function(self)
            local title_push = 0

            if (IsValid(self.imgIcon)) then self.imgIcon:SetPos(5, 5) self.imgIcon:SetSize(16, 16) title_push = 16 end

            self.btnClose:SetPos(self:GetWide() - 24 - 4, 0)     self.btnClose:SetSize(24, 24)
            self.btnMaxim:SetPos(self:GetWide() - 24 * 2 - 4, 0) self.btnMaxim:SetSize(24, 24)
            self.btnMinim:SetPos(self:GetWide() - 24 * 3 - 4, 0) self.btnMinim:SetSize(24, 24)
            self.lblTitle:SetPos(8 + title_push, 2)              self.lblTitle:SetSize(self:GetWide() - 25 - title_push, 20)
        end

        local grad_mat = Material("gui/gradient")
        window.Paint = function(self, w, h)
            surface.SetDrawColor(240, 240, 240)    surface.DrawRect(0, 0, w, h)
            surface.SetDrawColor(0, 0, 0)          surface.DrawOutlinedRect(0, 0, w, h, 1.5)
            surface.SetDrawColor(77, 79, 204, 215) surface.DrawRect(1, 1, w - 1.5, 23)
            surface.SetDrawColor(77, 79, 204)      surface.SetMaterial(grad_mat) surface.DrawTexturedRect(1, 1, w - 1.5, 23)
        end

        local con = vgui.Create("DPanel", window)
        con:Dock(FILL) con:DockMargin(0, 0, 0, 4)

        con.Paint = function(self, w, h) surface.SetDrawColor(215, 215, 215) surface.DrawRect(0, 0, w, h) end

        stdout:SetParent(con) stdout:Dock(FILL) stdout:DockMargin(0, 0, 0, 4) stdout:Show()

        local cmd = vgui.Create("DTextEntry", window)
        cmd:Dock(BOTTOM) cmd:SetHistoryEnabled(true) cmd:SetFont("DefaultFixed") cmd:SetUpdateOnType(true)

        cmd.Paint = function(self, w, h)
            surface.SetDrawColor(225, 225, 225) surface.DrawRect(0, 0, w, h)
            surface.SetDrawColor(127, 127, 127) surface.DrawOutlinedRect(0, 0, w, h, 1)
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
            myrealmax = function(_s) stdout_append(realmax_msg_size) end,
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
    local tblib_sort     = table.sort

    local netlib_send    = net.Send
    local netlib_rstring = net.ReadString
    local netlib_rdata   = net.ReadData

    local systime        = SysTime

    local isvalid        = IsValid

    local cfile_wbyte    = FindMetaTable("File").WriteByte

    util.AddNetworkString"mdlstream_req"
    util.AddNetworkString"mdlstream_frm" -- or Slice
    util.AddNetworkString"mdlstream_ack" -- Acknowledge

    local function deserialize_table(_s)
        local ret, cur_pos, pos = {}, 1, nil

        for i = 1, #_s do pos = str_find(_s, ",", cur_pos, true)
            if not pos then break end
            ret[i], cur_pos = tonumber(str_sub(_s, cur_pos, pos - 1)), pos + 1
        end ret[#ret + 1]   = tonumber(str_sub(_s, cur_pos))

        return ret
    end

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
        --- Sort based on IsValid(user), ping and requested file size(factor weight: decreasing)
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

    -- @BUFFER_SENSITIVE
    netlib_set_receiver("mdlstream_frm", function(_, user)
        local uid        = netlib_ruint64()
        local frame_type = netlib_ruintm()
        local content    = netlib_rdata(netlib_ruint())

        if frame_type == 200 then
            local bytes

            if #temp[uid][1] == 0 then
                bytes = deserialize_table(delzma(content))
            else
                temp[uid][1][#temp[uid][1] + 1] = content

                bytes = deserialize_table(delzma(tblib_concat(temp[uid][1])))
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
                string.FormattedTime(tlapse, "%03i:%03i:%03i"), path,
                user:SteamID64(), string.NiceSize(file_size(path, "DATA") / tlapse)))

            --- Clears garbage
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