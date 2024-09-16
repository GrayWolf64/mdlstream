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
-- @author GrayWolf, RiceMCUT
--
-- Example file sizes:
-- alyx.mdl len      : 444308(compressed: 390772), about 433kb
-- kleiner.mdl len   : 248252,                     about 240kb
mdlstream = {}

--- Shared konstants(not necessarily)
local max_msg_size         = 64000 - 3 - 1 - 3 - 3 - 3 -- bytes, 0.063 MB, around 100 msgs to transmit a 8 MB file
-- 3 spared for engine use
-- 1 for determining the response mode
-- #content for the actual partial(sliced) compressed string of byte sequence of target file
-- 3 for #content(slice / frame) length
-- 3 for #content frame ending position
-- 3 for uid of every accepted request, generated on client

local size_3bytes = 24
-- every uint we read and write will be a 24-bit one, max = 16777215, definitely abundant

local netlib_set_receiver = net.Receive
local netlib_start        = net.Start

local netlib_wuint        = function(_uint) net.WriteUInt(_uint, size_3bytes) end
local netlib_ruint        = function() return net.ReadUInt(size_3bytes) end

local netlib_wbool        = net.WriteBool
local netlib_rbool        = net.ReadBool

local str_sub             = string.sub
local tblib_concat        = table.concat

if CLIENT then
    local lzma            = util.Compress
    local netlib_wstring  = net.WriteString
    local netlib_toserver = net.SendToServer
    local cfile_eof       = FindMetaTable("File").EndOfFile
    local cfile_rbyte     = FindMetaTable("File").ReadByte
    local fun_donothing   = function() end

    local max_file_size = 8000000 -- bytes, 8 MB
    local file_formats  = {["mdl"] = true, ["vvd"] = true, ["phy"] = true}

    local function netlib_wbdata(_data)
        local _len = #_data
        netlib_wuint(_len)
        net.WriteData(_data, _len)
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
        assert(file_formats[string.GetExtensionFromFilename(path)], "MDLStream: Tries to send unsupported file, "      .. path)
        assert(file.Size(path, "GAME") <= max_file_size,            "MDLStream: Tries to send file larger than 8 MB, " .. path)

        if not callback or not isfunction(callback) then
            callback = fun_donothing
        end

        uid = uid + 1

        content_temp[uid] = {[1] = "", [2] = path, [3] = callback}

        netlib_start("mdlstream_request")
        netlib_wstring(path)
        netlib_wuint(uid)
        netlib_toserver()

        return true
    end

    netlib_set_receiver("mdlstream_ack", function()
        local blink_mode = netlib_rbool()
        local _uid       = netlib_ruint()

        netlib_start("mdlstream_frame")

        netlib_wuint(_uid)

        --- May better simplify section below
        if blink_mode == false then
            content_temp[_uid][1] = lzma(serialize_table(bytes_table(content_temp[_uid][2])))

            local _content = content_temp[_uid][1]

            local exceeds_max = #_content > max_msg_size
            netlib_wbool(exceeds_max)

            if not exceeds_max then
                netlib_wbdata(_content)
            else
                netlib_wbdata(str_sub(_content, 1, max_msg_size))

                netlib_wuint(max_msg_size)
            end
        elseif blink_mode == true then
            local _content = content_temp[_uid][1]
            local pos      = netlib_ruint()

            local exceeds_max = #_content - pos > max_msg_size

            netlib_wbool(exceeds_max)

            if not exceeds_max then
                netlib_wbdata(str_sub(_content, pos + 1, #_content))
            else
                local _endpos = pos + max_msg_size
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

    --- Testing only
    if LocalPlayer() then
        send_request("models/alyx.phy", function() print("test success") end)
        send_request("models/alyx.mdl")
        send_request("models/dog.mdl")
        send_request("models/kleiner.mdl")
    end

    mdlstream.SendRequest = send_request
else
    local delzma         = util.Decompress
    local tonumber       = tonumber
    local str_find       = string.find
    local netlib_send    = net.Send
    local netlib_rstring = net.ReadString
    local netlib_rdata   = net.ReadData
    local systime        = SysTime
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

    netlib_set_receiver("mdlstream_request", function(_, user)
        --- Whether checks file existence?
        --if not file.Exists(_path, "GAME") and not file.Exists(_path, "DATA") then
            netlib_start("mdlstream_ack")

            netlib_wbool(false)

            local _path = netlib_rstring()
            local _uid  = netlib_ruint()

            temp[_uid] = {[1] = {}, [2] = _path, [3] = systime()}

            netlib_wuint(_uid)

            netlib_send(user)
        --end
    end)

    netlib_set_receiver("mdlstream_frame", function(_, user)
        local _uid       = netlib_ruint()
        local frame_type = netlib_rbool()

        local content = netlib_rdata(netlib_ruint())

        if frame_type == false then
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

            print("MDLStream: took " .. string.NiceTime(systime() - temp[_uid][3])
                    .. " recv & build, " .. path, "from " .. user:SteamID64())

            --- Clears garbage
            temp[_uid][1] = nil
            temp[_uid][2] = nil
            temp[_uid][3] = nil

            netlib_start("mdlstream_fin")

            netlib_wuint(_uid)

            netlib_send(user)
        elseif frame_type == true then
            temp[_uid][1][#temp[_uid][1] + 1] = content

            netlib_start("mdlstream_ack")

            netlib_wbool(true)

            netlib_wuint(_uid)
            netlib_wuint(netlib_ruint())

            netlib_send(user)
        end
    end)
end