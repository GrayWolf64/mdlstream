--- MDLStream
-- @author GrayWolf, RiceMCUT
--
-- Example file sizes:
-- alyx.mdl len      : 444308(compressed: 390772), about 433kb
-- kleiner.mdl len   : 248252,                     about 240kb

local file_formats = {[".mdl"] = true, [".vvd"] = true, [".vtx"] = true}

local max_file_size      = 8000000 -- bytes, 8 MB

--- Konstants
local max_msg_size         = 64000 - 3 - 1 - 3 - 3   -- bytes, 0.064 MB, around 124 msgs to transmit a 8 MB file
-- 3 spared for engine use
-- 1 for determining the response mode
-- #content for the actual partial(sliced) compressed string of byte sequence of target file
-- 3 for #content length
-- 3 for #content slice ending position

local max_total_msg_size   = 255000  -- bytes, a limit on client msg queue(to be sent) size
local netlib_buffer_size   = 255000  -- bytes, 0.255 MB, internal reliable buffer

local lzma   = util.Compress
local delzma = util.Decompress

local netlib_set_receiver = net.Receive
local netlib_start        = net.Start
local netlib_wuint        = net.WriteUInt
local netlib_wbool        = net.WriteBool
local netlib_rbool        = net.ReadBool

local str_sub             = string.sub
local tblib_concat        = table.concat

if CLIENT then
    local netlib_wdata    = net.WriteData
    local netlib_toserver = net.SendToServer

    -- DO QUEUE

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

    local _content = ""

    local function send_request(path)
        netlib_start("mdlstream_request")
        net.WriteString(path)
        netlib_toserver()

        _content = lzma(serialize_table(bytes_table(path)))
    end

    netlib_set_receiver("mdlstream_svblink", function()
        local blink_mode = netlib_rbool()

        netlib_start("mdlstream_bslice")

        if blink_mode == false then
            local exceeds_max = #_content > max_msg_size
            netlib_wbool(exceeds_max)

            if not exceeds_max then
                netlib_wuint(#_content, 24)
                netlib_wdata(_content, #_content)
            else
                local _endpos = max_msg_size
                local _slice = str_sub(_content, 1, _endpos)

                netlib_wuint(#_slice, 24)
                netlib_wdata(_slice, #_slice)

                netlib_wuint(_endpos, 24)
            end
        elseif blink_mode == true then
            local pos = net.ReadUInt(24)
            local exceeds_max = #_content - pos > max_msg_size

            netlib_wbool(exceeds_max)

            if not exceeds_max then
                local _slice = str_sub(_content, pos + 1, #_content)

                netlib_wuint(#_slice, 24)
                netlib_wdata(_slice, #_slice)
            else
                local _endpos = pos + max_msg_size
                local _slice = str_sub(_content, pos + 1, _endpos)

                netlib_wuint(#_slice, 24)
                netlib_wdata(_slice, #_slice)

                netlib_wuint(_endpos, 24)
            end
        end

        netlib_toserver()
    end)

    send_request("models/alyx.phy")
    send_request("models/alyx.mdl")
else
    local tonumber     = tonumber
    local str_find     = string.find
    local tblib_insert = table.insert
    local netlib_send  = net.Send

    util.AddNetworkString("mdlstream_request")
    util.AddNetworkString("mdlstream_bslice")
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

    local _context_path = ""

    netlib_set_receiver("mdlstream_request", function(_, user)
        _context_path = net.ReadString()

        --if not file.Exists(_context_path, "GAME") then
            netlib_start("mdlstream_svblink")
            netlib_wbool(0)
            netlib_send(user)
        --end
    end)

    local _slices = {} -- FIXME

    netlib_set_receiver("mdlstream_bslice", function(_, user)
        local slice_type = netlib_rbool()

        local content = net.ReadData(net.ReadUInt(24))

        file.CreateDir(string.GetPathFromFilename(_context_path))

        if slice_type == false then
            local bytes

            if #_slices == 0 then
                bytes = deserialize_table(delzma(content))
            else
                tblib_insert(_slices, content)

                bytes = deserialize_table(delzma(tblib_concat(_slices)))
            end

            local _f = file.Open(_context_path, "wb", "DATA")

            for i = 1, #bytes do
                _f:WriteByte(bytes[i])
            end

            _f:Close()
        elseif slice_type == true then
            tblib_insert(_slices, content)

            netlib_start("mdlstream_svblink")
            netlib_wbool(true)
            netlib_wuint(net.ReadUInt(24), 24)
            netlib_send(user)
        end
    end)
end

-- if SERVER then
--     local e = ents.Create("prop_ragdoll")
--     e:SetModel("data/models/alyx.mdl")
--     e:SetPos(Entity(1):GetPos())
--     e:Spawn()
-- end