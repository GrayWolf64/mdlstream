--- MDLStream
-- Sync necessary files of client models to server so that server can initialize models' physics
-- For use with cloud asset related addons
-- Specifications:
-- Max file size: 8 MB
-- Limited file formats
-- Handshake styled transmission
--
-- Possible Workflow: Client Request ==> Server receives Request ==> Server Blinks(acknowledge) ==> Client receives Blink
-- ==> Client sends frame ==> Server receives frame ==> Server builds file(transmisson finished) / Server Blinks
-- ==> Client receives Blink ==> Client sends frame ==> ... Until all frames of file content are fully received, then build(transmisson finished)
--
-- @author GrayWolf, RiceMCUT, Wolf109909
--
-- Example file sizes:
-- alyx.mdl len      : 444308(compressed: 390772), about 433kb
-- kleiner.mdl len   : 248252,                     about 240kb
--
-- More on MDL: https://developer.valvesoftware.com/wiki/MDL_(Source)
-- Thanks to https://github.com/ZeqMacaw/Crowbar/tree/0d46f3b6a694b74453db407c72c12a9685d8eb1d/Crowbar/Core/GameModel
-- for some crucial hints on mdl header1
if not gmod or game.SinglePlayer() then return end

mdlstream = {}

--- Shared konstants(not necessarily)
local max_msg_size         = 64000 - 3 - 1 - 3 - 3 - 3 -- bytes, 0.063 MB, around 100 msgs to transmit a 8 MB file
-- 3 spared for engine use
-- 1 for determining the response mode
-- #content for the actual partial(sliced) compressed string of byte sequence of target file
-- 3 for #content(slice / frame) length
-- 3 for #content frame ending position
-- 3 for uid of every accepted request, generated on client

local tonumber            = tonumber

local netlib_set_receiver = net.Receive
local netlib_start        = net.Start

-- every uint we read and write will be a 24-bit one, max = 16777215, definitely abundant
local netlib_wuint        = function(_uint) net.WriteUInt(_uint, 24) end
local netlib_ruint        = function() return net.ReadUInt(24) end

--- dedicated to read and write response mode, max = 255
--
-- 100: Server has accepted Client's request, awaits for the first frame
-- 101: Server awaits for subsequent frame
-- 200: Client sends a frame that can be received and built on Server using previously received frames or
--      this request consists only one frame
-- 201: Client sends a frame that requires Server's subsequent frame-save and `101` ACK msg
local netlib_wuintm       = function(_uint) net.WriteUInt(_uint, 8) end
local netlib_ruintm       = function() return net.ReadUInt(8) end

local str_sub             = string.sub
local tblib_concat        = table.concat
local tblib_remove        = table.remove

local file_size           = file.Size

local mstr                = function(_s) return "MDLStream: " .. _s end

if CLIENT then
    local lzma             = util.Compress

    local netlib_wstring   = net.WriteString
    local netlib_toserver  = net.SendToServer

    local cfile_eof        = FindMetaTable("File").EndOfFile
    local cfile_rbyte      = FindMetaTable("File").ReadByte

    local str_ext_fromfile = string.GetExtensionFromFilename

    local fun_donothing    = function() end

    local realmax_msg_size = max_msg_size

    local max_file_size = 8000000 -- bytes, 8 MB
    local file_formats  = {["mdl"] = true, ["vvd"] = true, ["phy"] = true}

    local function netlib_wbdata(_data)
        local _len = #_data
        netlib_wuint(_len)
        net.WriteData(_data, _len)
    end

    local determinant = {
        id = {73, 68, 83, 84}, -- "IDST". no "MDLZ"
        versions = {
            --- Known: 4 is "HLAlpha", 6, 10 is "HLStandardSDK" related, too old that is out of scope of this project
            -- [4] = true, [6]  = true, [10] = true,
            [14]   = true,
            [2531] = true, [27] = true, [28] = true, [29] = true,
            [30]   = true, [31] = true, [32] = true, [35] = true, [36] = true, [37] = true,
            [44]   = true, [45] = true, [46] = true, [47] = true, [48] = true, [49] = true,
            [52]   = true, [53] = true, [54] = true, [55] = true, [56] = true, [58] = true, [59] = true
        }
    }

    local function validate_header(_path)
        local ext = str_ext_fromfile(_path)

        local _file = file.Open(_path, "rb", "GAME")
        if not _file then return false end

        --- https://github.com/Tieske/pe-parser/blob/master/src/pe-parser.lua
        if ext == "vvd" or ext == "phy" then
            if _file:Read(2) == "MZ" then return false end

            return true
        end

        local function read_cint()
            return {cfile_rbyte(_file), cfile_rbyte(_file), cfile_rbyte(_file), cfile_rbyte(_file)}
        end

        local function hext_to_int(_t)
            return tonumber(string.format("0x%x%x%x%x", _t[4], _t[3], _t[2], _t[1]))
        end

        local studiohdr_t = {
            id       = read_cint(),
            version  = read_cint(),
            checksum = read_cint(),
            name     = _file:Read(64),
            datalen  = read_cint()
        }

        _file:Close()

        if studiohdr_t.id[1] ~= determinant.id[1] or studiohdr_t.id[2] ~= determinant.id[2] or
            studiohdr_t.id[3] ~= determinant.id[3] or studiohdr_t.id[4] ~= determinant.id[4] then
            return false
        end

        if not determinant.versions[hext_to_int(studiohdr_t.version)]   then return false end
        if not studiohdr_t.checksum or not #studiohdr_t.checksum == 4   then return false end
        if not studiohdr_t.name                                         then return false end
        if hext_to_int(studiohdr_t.datalen) ~= file_size(_path, "GAME") then return false end

        return true
    end

    local uid = uid or 1 -- included in msg
    -- To ensure that we don't lose the identity of one file's content when this client request to send another
    -- which leads to overriding of file content
    -- With the specified player and uid, we can tell every file

    local content_temp = content_temp or {}

    local function bytes_table(_path)
        local _file = file.Open(_path, "rb", "GAME")

        local bytes = {}

        for i = 1, math.huge do
            if cfile_eof(_file) then break end

            bytes[i] = cfile_rbyte(_file)
        end

        _file:Close()

        return bytes
    end

    local function serialize_table(_t)
        return tblib_concat(_t, ",")
    end

    local function send_request(path, callback)
        assert(isstring(path),                          mstr"'path' is not a string")
        assert(isfunction(callback) or callback == nil, mstr"'callback' is not nil or function")

        assert(file.Exists(path, "GAME"),               mstr"desired 'filepath' does not exist on client, "   .. path)

        assert(file_formats[str_ext_fromfile(path)],     mstr"Tries to send unsupported file, "               .. path)
        assert(file_size(path, "GAME") <= max_file_size, mstr"Tries to send file larger than 8 MB, "          .. path)
        assert(validate_header(path),                    mstr"Corrupted or intentionally bad file (header), " .. path)

        if not callback or not isfunction(callback) then
            callback = fun_donothing
        end

        uid = uid + 1

        content_temp[uid] = {[1] = lzma(serialize_table(bytes_table(path))), [2] = path, [3] = callback}

        netlib_start("mdlstream_request")
        netlib_wstring(path)
        netlib_wuint(uid)
        netlib_toserver()
    end

    --- Based on assumptions
    -- In the worst case, a 8 MB file takes about 3334 messages to transmit,
    -- we'd better hope that this client's net condition will get better,
    -- otherwise, he will probably wait forever or quit and get some better gear
    local function adjust_max_msg_size()
        if not LocalPlayer() then return end

        local ping = LocalPlayer():Ping()

        if     ping <= 30                 then realmax_msg_size = max_msg_size
        elseif ping >= 31  and ping < 50  then realmax_msg_size = max_msg_size - 6000
        elseif ping >= 51  and ping < 100 then realmax_msg_size = max_msg_size - 16000
        elseif ping >= 101 and ping < 200 then realmax_msg_size = max_msg_size - 30000
        else                                   realmax_msg_size = 24000 end
    end

    local function wmode_frame(_exceeds)
        if not _exceeds then netlib_wuintm(200) else netlib_wuintm(201) end
    end

    netlib_set_receiver("mdlstream_ack", function()
        local _mode = netlib_ruintm()
        local _uid  = netlib_ruint()

        netlib_start("mdlstream_frame")

        netlib_wuint(_uid)

        adjust_max_msg_size()

        --- May better simplify section below
        if _mode == 100 then
            local _content = content_temp[_uid][1]

            local exceeds_max = #_content > realmax_msg_size
            wmode_frame(exceeds_max)

            if not exceeds_max then
                netlib_wbdata(_content)
            else
                netlib_wbdata(str_sub(_content, 1, realmax_msg_size))

                netlib_wuint(realmax_msg_size)
            end
        elseif _mode == 101 then
            local _content = content_temp[_uid][1]
            local pos      = netlib_ruint()

            local exceeds_max = #_content - pos > realmax_msg_size
            wmode_frame(exceeds_max)

            if not exceeds_max then
                netlib_wbdata(str_sub(_content, pos + 1, #_content))
            else
                local _endpos = pos + realmax_msg_size
                local _frame = str_sub(_content, pos + 1, _endpos)

                netlib_wbdata(_frame)

                netlib_wuint(_endpos)
            end
        end

        netlib_toserver()
    end)

    netlib_set_receiver("mdlstream_fin", function()
        local _uid = netlib_ruint()
        --- Clears garbage on client's delicate computer
        -- can we keep the path in cache to speed check-file process?
        content_temp[_uid][1] = nil
        content_temp[_uid][2] = nil

        pcall(content_temp[_uid][3])

        content_temp[_uid][3] = nil
    end)

    mdlstream.SendRequest = send_request
else
    local delzma         = util.Decompress
    local str_find       = string.find

    local netlib_send    = net.Send
    local netlib_rstring = net.ReadString
    local netlib_rdata   = net.ReadData

    local systime        = SysTime

    local isvalid        = IsValid

    local cfile_wbyte    = FindMetaTable("File").WriteByte

    util.AddNetworkString"mdlstream_request"
    util.AddNetworkString"mdlstream_frame" -- or Slice
    util.AddNetworkString"mdlstream_ack" -- Acknowledge
    util.AddNetworkString"mdlstream_fin" -- Final

    local function deserialize_table(_s)
        local ret = {}
        local current_pos = 1
        local start_pos, end_pos

        for i = 1, #_s do
            start_pos, end_pos = str_find(_s, ",", current_pos, true)

            if not start_pos then break end

            ret[i] = tonumber(str_sub(_s, current_pos, start_pos - 1))
            current_pos = end_pos + 1
        end

        ret[#ret + 1] = tonumber(str_sub(_s, current_pos))

        return ret
    end

    --- I don't want to go oop here, though it may be more elegant
    local temp = temp or {}

    local queue = queue or {}

    netlib_set_receiver("mdlstream_request", function(_, user)
        if not isvalid(user) then return end

        local _path = netlib_rstring()
        local _uid  = netlib_ruint()

        --- Whether checks file existence?
        --if not file.Exists(_path, "GAME") and not file.Exists(_path, "DATA") then
        local function action()
            netlib_start("mdlstream_ack")

            netlib_wuintm(100)

            temp[_uid] = {[1] = {}, [2] = _path, [3] = systime()}

            netlib_wuint(_uid)

            netlib_send(user)
        end

        queue[#queue + 1] = {[1] = action, [2] = false, [3] = user}
        --end
    end)

    do
        local qhead

        timer.Create("mdlstream_watcher", 0.875, 0, function()
            qhead = queue[1]

            --- gone player has occupied the first slot in queue, abandon it
            if qhead and not isvalid(qhead[3]) then tblib_remove(queue, 1) end

            if not qhead or qhead[2] then return end
            qhead[1]()
            queue[1][2] = true
        end)
    end

    netlib_set_receiver("mdlstream_frame", function(_, user)
        if not isvalid(user) then return end

        local _uid       = netlib_ruint()
        local frame_type = netlib_ruintm()

        local content = netlib_rdata(netlib_ruint())

        if frame_type == 200 then
            local bytes

            if #temp[_uid][1] == 0 then
                bytes = deserialize_table(delzma(content))
            else
                temp[_uid][1][#temp[_uid][1] + 1] = content

                bytes = deserialize_table(delzma(tblib_concat(temp[_uid][1])))
            end

            local path = temp[_uid][2]

            file.CreateDir(string.GetPathFromFilename(path))

            local _file = file.Open(path, "wb", "DATA")

            for i = 1, #bytes do
                cfile_wbyte(_file, bytes[i])
            end

            _file:Close()

            local tlapse = systime() - temp[_uid][3]

            print(mstr"took " .. string.FormattedTime(tlapse, "%03i:%03i:%03i")
                    .. " recv & build, '" .. path .. "'", "from " .. user:SteamID64() .. ";"
                    .. " avg spd, " .. string.NiceSize(file_size(path, "DATA") / tlapse) .. "/s")

            --- Clears garbage
            temp[_uid][1] = nil
            temp[_uid][2] = nil
            temp[_uid][3] = nil

            tblib_remove(queue, 1)

            netlib_start("mdlstream_fin")
            netlib_wuint(_uid)
        elseif frame_type == 201 then
            temp[_uid][1][#temp[_uid][1] + 1] = content

            netlib_start("mdlstream_ack")

            netlib_wuintm(101)

            netlib_wuint(_uid)
            netlib_wuint(netlib_ruint())
        end

        netlib_send(user)
    end)
end

--- Testing only
-- if CLIENT and LocalPlayer() then
--     send_request("models/alyx.phy", function() print("alyx phy download success callback") end)
--     send_request("models/alyx.mdl"); send_request("models/alyx.vvd")
--     send_request("models/kleiner.mdl"); send_request("models/kleiner.phy")
--     send_request("models/dog.mdl")
-- end