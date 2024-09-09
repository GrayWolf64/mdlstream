--- MDLStream
-- Sync necessary files of client models to server so that server can initialize models' physics
-- For use with cloud asset related addons
-- Specifications:
-- Max file size: 8 MB
-- Limited file formats
--
-- Possible Workflow: Client Request ==> Server receives Request ==> Server Blinks ==> Client receives Blink
-- ==> Client sends Slice ==> Server receives Slice ==> Server builds file(transmisson finished) / Server Blinks
-- ==> Client receives Blink ==> Client sends Slice ==> ... Until all slices of file content are fully received, then build(transmisson finished)
--
-- @author GrayWolf, RiceMCUT
--
-- Example file sizes:
-- alyx.mdl len      : 444308(compressed: 390772), about 433kb
-- kleiner.mdl len   : 248252,                     about 240kb
MDLStream = {}

--- Shared konstants
local max_msg_size         = 64000 - 3 - 1 - 3 - 3 - 3 - 3 - 3  -- bytes, 0.063 MB, around 100 msgs to transmit a 8 MB file
-- 3 spared for engine use
-- 1 for determining the response mode
-- #content for the actual partial(sliced) compressed string of byte sequence of target file
-- 3 for #content(slice) length
-- 3 for #content slice ending position
-- 3 for uid of every accepted request
-- 3 for uid of content clientside
-- 3 for uid of content path

local size_3bytes = 24
-- every uint we read and write will be a 24-bit one, max = 16777215

local netlib_set_receiver = net.Receive
local netlib_start        = net.Start

local netlib_wuint        = function(_uint) net.WriteUInt(_uint, size_3bytes) end
local netlib_ruint        = function() return net.ReadUInt(size_3bytes) end

local netlib_wbool        = net.WriteBool
local netlib_rbool        = net.ReadBool

local str_sub             = string.sub
local tblib_concat        = table.concat

if CLIENT then
    local lzma   = util.Compress

    local max_file_size      = 8000000 -- bytes, 8 MB

    local file_formats = {["mdl"] = true, ["vvd"] = true, ["phy"] = true}

    local errorstr_unsupported_format = "MDLStream: Tries to send unsupported file, "
    local errorstr_size_abnormal      = "MDLStream: Tries to send file larger than 8 MB, "

    local netlib_wstring  = net.WriteString
    local netlib_wdata    = net.WriteData
    local netlib_toserver = net.SendToServer

    local content_uid  = content_uid or 1 -- included in msg
    -- To ensure that we don't lose the identity of one file's content when this client request to send another
    -- which leads to overriding of file content

    local content_temp = content_temp or {}

    local function bytes_table(_path)
        local _file = file.Open(_path, "rb", "GAME")

        local bytes = {}

        while not _file:EndOfFile() do
            bytes[#bytes + 1] = _file:ReadByte()
        end

        _file:Close()

        return bytes
    end

    local function serialize_table(_t)
        return tblib_concat(_t, ",")
    end

    local function send_request(path)
        if not file_formats[string.GetExtensionFromFilename(path)] then
            ErrorNoHalt(errorstr_unsupported_format, path)

            return false
        end

        if file.Size(path, "GAME") > max_file_size then
            ErrorNoHalt(errorstr_size_abnormal, path)

            return false
        end

        content_uid = content_uid + 1

        netlib_start("mdlstream_request")
        netlib_wstring(path)
        netlib_wuint(content_uid)
        netlib_toserver()

        content_temp[content_uid] = lzma(serialize_table(bytes_table(path)))

        return true
    end

    netlib_set_receiver("mdlstream_svblink", function()
        local blink_mode   = netlib_rbool()
        local uid          = netlib_ruint()

        netlib_start("mdlstream_slice")

        netlib_wuint(uid)

        --- May better simplify section below
        local _content_uid
        if blink_mode == false then
            _content_uid   = netlib_ruint()
            local _content = content_temp[_content_uid]

            local exceeds_max = #_content > max_msg_size
            netlib_wbool(exceeds_max)

            if not exceeds_max then
                netlib_wuint(#_content)
                netlib_wdata(_content, #_content)
            else
                local _endpos = max_msg_size
                local _slice = str_sub(_content, 1, _endpos)

                netlib_wuint(#_slice)
                netlib_wdata(_slice, #_slice)

                netlib_wuint(_endpos)
            end
        elseif blink_mode == true then
            local pos    = netlib_ruint()
            _content_uid = netlib_ruint()

            local _content = content_temp[_content_uid]
            local exceeds_max = #_content - pos > max_msg_size

            netlib_wbool(exceeds_max)

            if not exceeds_max then
                local _slice = str_sub(_content, pos + 1, #_content)

                netlib_wuint(#_slice)
                netlib_wdata(_slice, #_slice)
            else
                local _endpos = pos + max_msg_size
                local _slice = str_sub(_content, pos + 1, _endpos)

                netlib_wuint(#_slice)
                netlib_wdata(_slice, #_slice)

                netlib_wuint(_endpos)
            end
        end

        netlib_wuint(_content_uid)

        netlib_wuint(netlib_ruint())

        netlib_toserver()
    end)

    MDLStream.SendRequest = send_request

    -- send_request("models/alyx.phy")
    -- send_request("models/alyx.mdl")
    -- send_request("models/dog.mdl")
else
    local delzma       = util.Decompress
    local tonumber     = tonumber
    local str_find     = string.find
    local tblib_insert = table.insert
    local netlib_send  = net.Send

    local uid = uid or 1 -- included in msg
    -- To ensure that every slice goes to a specific, corresponding field of a temp table
    -- for later file build

    local path_uid = path_uid or 1 -- included in msg
    -- To ensure that every file is saved to a specific, corresponding location on server

    --- Client Request:
    -- writes path:string
    -- writes clientside uid:int for content
    --
    --- Server receives Request:
    -- reads path
    -- writes mode:bool
    -- writes uid:int for serverside slice
    -- reads and writes uid for clientside content
    -- ==> Server starts blink
    --
    --- Client receives Blink:
    -- reads mode
    -- reads uid(serverside slice) that reminds server
    -- writes uid(serverside slice)
    -- writes mode(slice type)
    -- writes int content size
    -- (optional if) reads int last endpos (content uid: uncertain position, may be after reading endpos)
    -- writes data
    -- (optional if) writes int endpos
    -- writes uid(clientside content)
    -- ==> Client starts slice
    --
    --- Server receives Slice:
    -- reads uid(serverside slice)
    -- reads bool(slice type)
    -- reads int(content size)
    -- reads data
    -- (optional if) writes bool
    --               writes int(serverside slice)
    --               reads and writes uid(clientside content)
    --               ==> Server starts blink, saves slice
    -- (optional if) ==> Server saves slice then build file
    util.AddNetworkString("mdlstream_request")
    util.AddNetworkString("mdlstream_slice")
    util.AddNetworkString("mdlstream_svblink")

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

    local context_paths = context_paths or {}
    local slices_temp   = slices_temp or {}

    netlib_set_receiver("mdlstream_request", function(_, user)
        path_uid = path_uid + 1
        context_paths[path_uid] = net.ReadString()

        --- Whether checks file existence?
        --if not file.Exists(context_paths[uid], "GAME") then
            uid = uid + 1
            slices_temp[uid] = {}
            netlib_start("mdlstream_svblink")
            netlib_wbool(false)
            netlib_wuint(uid)
            netlib_wuint(netlib_ruint())

            netlib_wuint(path_uid)

            netlib_send(user)
        --end
    end)

    netlib_set_receiver("mdlstream_slice", function(_, user)
        local _uid       = netlib_ruint()
        local slice_type = netlib_rbool()

        local content = net.ReadData(netlib_ruint())

        if slice_type == false then
            local bytes

            if #slices_temp[_uid] == 0 then
                bytes = deserialize_table(delzma(content))
            else
                tblib_insert(slices_temp[_uid], content)

                bytes = deserialize_table(delzma(tblib_concat(slices_temp[_uid])))
            end

            netlib_ruint()
            local _path_uid = netlib_ruint()

            file.CreateDir(string.GetPathFromFilename(context_paths[_path_uid]))

            local _file = file.Open(context_paths[_path_uid], "wb", "DATA")

            for i = 1, #bytes do
                _file:WriteByte(bytes[i])
            end

            _file:Close()
        elseif slice_type == true then
            tblib_insert(slices_temp[_uid], content)

            netlib_start("mdlstream_svblink")
            netlib_wbool(true)
            netlib_wuint(_uid)
            netlib_wuint(netlib_ruint())
            netlib_wuint(netlib_ruint())
            netlib_wuint(netlib_ruint())

            netlib_send(user)
        end
    end)
end