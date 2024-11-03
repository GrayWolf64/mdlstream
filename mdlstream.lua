--- MDLStream
-- Sync necessary files of client models to server so that server can initialize models' physics
-- For use with addons which require clientside model files to be sent to server
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
-- `flag_noclui`:  Disables clientside debugger GUI; Routes some terminal(debugger ui) messages to engine console
-- `flag_allperm`: Disables permission(admin) check when performing certain non-programmatic actions, like `request`
-- `flag_keepobj`: True to keep original downloaded file, false to only keep encapsulated .gma
local flag_testing = true
local flag_noclui  = false
local flag_allperm = true
local flag_keepobj = false

--- Shared konstants(not necessarily)
-- ! Unless otherwise stated, all the numbers related to msg sizes are all in 'bytes'
--
-- FRAME content:
-- 3 spared for engine use
-- 1 for determining the response mode
-- #content for the actual partial(sliced) compressed string of byte sequence of target file
-- 3 for #content(slice / frame) length
-- 3 for #content frame ending position
-- 8 for uid(int64:str) of every accepted request, generated on client
-- some bytes spared for testing the most optimal size
local max_msg_size        = 65536 - 3 - 1 - 3 - 3 - 8 - 11518

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

    local mdl_determinant = {
        id = {73, 68, 83, 84}, -- "IDST". no "MDLZ"
        versions = {
            --- Known: 4 is "HLAlpha", 6, 10 is "HLStandardSDK" related
            -- 14 is used in "Half-Life SDK", too old
            -- [2531] = true, [27] = true, [28] = true, [29] = true,
            -- [30]   = true, [31] = true, [32] = true, [35] = true, [36] = true, [37] = true,
            [44]   = true, [45] = true, [46] = true, [47] = true, [48] = true, [49] = true,
            [52]   = true, [53] = true, [54] = true, [55] = true, [56] = true, [58] = true, [59] = true
        }
    }

    local STUDIO_PROC_TYPE = {
        STUDIO_PROC_AXISINTERP = 1,
        STUDIO_PROC_QUATINTERP = 2,
        STUDIO_PROC_AIMATBONE = 3,
        STUDIO_PROC_AIMATATTACH = 4,
        STUDIO_PROC_JIGGLE = 5
    }

    local STUDIO_FRAMEANIM = 0x0040

    local function read_cint(_file) return {cfile_rbyte(_file), cfile_rbyte(_file), cfile_rbyte(_file), cfile_rbyte(_file)} end
    local function read_cvec(_file) return {_file:ReadFloat(), _file:ReadFloat(), _file:ReadFloat()} end
    local function read_cquat(_file) return {_file:ReadFloat(), _file:ReadFloat(), _file:ReadFloat(), _file:ReadFloat()} end
    local function read_str_nullend(_file)
        local char = _file:Read(1)
        local _s = {}
        while char ~= "\0" do
            _s[#_s + 1] = char
            char = _file:Read(1)
        end
        return tblib_concat(_s)
    end

    -- TODO: below is targeted at ver44, make it suitable for above vers
    -- https://github.com/RaphaelIT7/sourcesdk-gmod/blob/313ac36bded1d9ae1b74fcbdf0f5d780c3b6fabc/public/studio.h#L2062-L2340
    -- https://github.com/RaphaelIT7/sourcesdk-gmod/blob/main/utils/studiomdl/write.cpp#L2753-#L3123
    -- https://github.com/RaphaelIT7/sourcesdk-gmod/blob/313ac36bded1d9ae1b74fcbdf0f5d780c3b6fabc/utils/mdlinfo/main.cpp
    local function read_model(_path, only_simple_info)
        local _file = file_open(_path, "rb", "GAME")

        local _h = {}

        _h.id       = _file:ReadLong()
        _h.version  = _file:ReadLong()
        _h.checksum = _file:ReadLong()
        _h.name     = _file:Read(64)
        _h.length   = _file:ReadLong()

        if only_simple_info then _file:Close() return _h end

        local _data = {}

        _h.eyeposition = read_cvec(_file); _h.illumposition = read_cvec(_file)

        _h.hull_min    = read_cvec(_file); _h.hull_max      = read_cvec(_file)

        _h.view_bbmin  = read_cvec(_file); _h.view_bbmax    = read_cvec(_file)

        _h.flags = _file:ReadLong()

        _h.numbones            = _file:ReadLong(); _h.boneindex           = _file:ReadLong()

        _h.numbonecontrollers  = _file:ReadLong(); _h.bonecontrollerindex = _file:ReadLong()

        _h.numhitboxsets       = _file:ReadLong(); _h.hitboxsetindex      = _file:ReadLong()

        _h.numlocalanim        = _file:ReadLong(); _h.localanimindex      = _file:ReadLong()

        _h.numlocalseq         = _file:ReadLong(); _h.localseqindex       = _file:ReadLong()

        _h.activitylistversion = _file:ReadLong(); _h.eventsindexed       = _file:ReadLong()

        _h.numtextures         = _file:ReadLong(); _h.textureindex        = _file:ReadLong()

        _h.numcdtextures       = _file:ReadLong(); _h.cdtextureindex      = _file:ReadLong()

        _h.numskinref = _file:ReadLong(); _h.numskinfamilies = _file:ReadLong(); _h.skinindex = _file:ReadLong()

        _h.numbodyparts        = _file:ReadLong(); _h.bodypartindex        = _file:ReadLong()

        _h.numlocalattachments = _file:ReadLong(); _h.localattachmentindex = _file:ReadLong()

        _h.numlocalnodes = _file:ReadLong(); _h.localnodeindex = _file:ReadLong(); _h.localnodenameindex = _file:ReadLong()

        _h.numflexdesc            = _file:ReadLong(); _h.flexdescindex       = _file:ReadLong()

        _h.numflexcontrollers     = _file:ReadLong(); _h.flexcontrollerindex = _file:ReadLong()

        _h.numflexrules           = _file:ReadLong(); _h.flexruleindex       = _file:ReadLong()

        _h.numikchains            = _file:ReadLong(); _h.ikchainindex        = _file:ReadLong()

        _h.nummouths              = _file:ReadLong(); _h.mouthindex          = _file:ReadLong()

        _h.numlocalposeparameters = _file:ReadLong(); _h.localposeparamindex = _file:ReadLong()

        _h.surfacepropindex = _file:ReadLong()

        if _h.surfacepropindex > 0 then
            local input_pos = _file:Tell()

            _file:Seek(_h.surfacepropindex)

            _data.surfacepropname = read_str_nullend(_file)

            _file:Seek(input_pos)
        end

        _h.keyvalueindex           = _file:ReadLong(); _h.keyvaluesize             = _file:ReadLong()

        _h.numlocalikautoplaylocks = _file:ReadLong(); _h.localikautoplaylockindex = _file:ReadLong()

        _h.mass = _file:ReadFloat()

        _h.contents = _file:ReadLong()

        _h.numincludemodels  = _file:ReadLong(); _h.includemodelindex = _file:ReadLong()

        _h.virtualmodel = _file:ReadLong()

        _h.szanimblocknameindex = _file:ReadLong()
        _h.numanimblocks        = _file:ReadLong()
        _h.animblockindex       = _file:ReadLong()
        _h.animblockModel       = _file:ReadLong()

        if _h.numanimblocks > 0 then
            local input_pos = _file:Tell()
            if _h.szanimblocknameindex > 0 then
                _file:Seek(_h.szanimblocknameindex)

                _data.animblockname = read_str_nullend(_file)
            end

            if _h.animblockindex > 0 then
                _file:Seek(_h.animblockindex)

                _data.animblocks = {}
                for i = 1, _h.numanimblocks do
                    _data.animblocks[i] = {}
                    _data.animblocks[i].datastart = _file:ReadLong()
                    _data.animblocks[i].dataend   = _file:ReadLong()
                end
            end
            _file:Seek(input_pos)
        end

        _h.bonetablebynameindex = _file:ReadLong()

        _h.pVertexBase = _file:ReadLong()
        _h.pIndexBase  = _file:ReadLong()

        _h.constdirectionallightdot = _file:ReadByte()
        _h.rootLOD                  = _file:ReadByte()
        _h.numAllowedRootLODs       = _file:ReadByte()

        _h.unused0 = _file:ReadByte()
        _h.unused1 = _file:ReadLong()

        _h.numflexcontrolleruic  = _file:ReadLong()
        _h.flexcontrolleruiindex = _file:ReadLong()

        _h.flVertAnimFixedPointScale = _file:ReadFloat()

        _h.unused2 = _file:ReadLong()

        _h.studiohdr2index = _file:ReadLong()

        _h.unused3 = _file:ReadLong()

        local _h2
        if _h.studiohdr2index > 0 then
            _h2 = {}

            _h2.srcbonetransform_count = _file:ReadLong()
            _h2.srcbonetransform_index = _file:ReadLong()

            _h2.illumpositionattachmentindex = _file:ReadLong()
            _h2.flMaxEyeDeflection           = _file:ReadFloat()
            _h2.linearbone_index             = _file:ReadLong()

            _h2.namecopyindex = _file:ReadLong()
            if _h2.namecopyindex > 0 then
                local input_pos = _file:Tell()

                _data.namecopy = read_str_nullend(_file)

                _file:Seek(input_pos)
            end

            -- TODO: verify this
            _h2.m_nBoneFlexDriverCount = _file:ReadLong()
            _h2.m_nBoneFlexDriverIndex = _file:ReadLong()

            _h2.unknown = {}
            for i = 1, 56 do _h2.unknown[i] = _file:ReadLong() end
        end

        local bones = {}
        if _h.numbones > 0 then
            local boneinput_pos
            local input_pos

            local bone
            for i = 1, _h.numbones do
                boneinput_pos = _file:Tell()

                bone = {}

                bone.nameindex   = _file:ReadLong()
                bone.parentindex = _file:ReadLong()

                bone.bonecontrollerindex = {}
                for j = 1, 6 do
                    bone.bonecontrollerindex[j] = _file:ReadLong()
                end

                bone.position = read_cvec(_file)

                bone.quat     = read_cquat(_file)
                bone.rotation = read_cvec(_file)

                bone.positionscale = read_cvec(_file)
                bone.rotationscale = read_cvec(_file)

                bone.posetobone = {
                    {_file:ReadFloat(), _file:ReadFloat(), _file:ReadFloat(), _file:ReadFloat()},
                    {_file:ReadFloat(), _file:ReadFloat(), _file:ReadFloat(), _file:ReadFloat()},
                    {_file:ReadFloat(), _file:ReadFloat(), _file:ReadFloat(), _file:ReadFloat()}
                }

                bone.qalignment = read_cquat(_file)

                bone.flags = _file:ReadLong()

                bone.proceduralruletype   = _file:ReadLong()
                bone.proceduralruleindex  = _file:ReadLong()
                bone.physicsboneindex     = _file:ReadLong()
                bone.surfacepropnameindex = _file:ReadLong()
                bone.contents             = _file:ReadLong()

                bone.unused = {}
                for j = 1, 8 do
                    bone.unused[j] = _file:ReadLong()
                end

                input_pos = _file:Tell()

                if bone.nameindex ~= 0 then
                    _file:Seek(boneinput_pos + bone.nameindex)

                    bone.name = read_str_nullend(_file)
                else
                    bone.name = ""
                end

                if bone.proceduralruleindex ~= 0 then
                    _file:Seek(boneinput_pos + bone.proceduralruleindex)

                    if bone.proceduralruletype == STUDIO_PROC_TYPE.STUDIO_PROC_AXISINTERP then
                        bone.axisinterpbone = {}
                        bone.axisinterpbone.control = _file:ReadLong()

                        bone.axisinterpbone.pos = {}
                        for j = 1, 5 do
                            bone.axisinterpbone.pos[j] = read_cvec(_file)
                        end

                        bone.axisinterpbone.quat = {}
                        for j = 1, 5 do
                            bone.axisinterpbone.quat[j] = read_cquat(_file)
                        end

                        _file:Seek(input_pos)
                    elseif bone.proceduralruletype == STUDIO_PROC_TYPE.STUDIO_PROC_QUATINTERP then
                        local quatinterpboneinput_pos = _file:Tell()

                        bone.quatinterpbone = {}
                        bone.quatinterpbone.control      = _file:ReadLong()
                        bone.quatinterpbone.numtriggers  = _file:ReadLong()
                        bone.quatinterpbone.triggerindex = _file:ReadLong()

                        bone.quatinterpbone.triggers = {}
                        if bone.quatinterpbone.numtriggers > 0 and bone.quatinterpbone.triggerindex ~= 0 then
                            _file:Seek(quatinterpboneinput_pos + bone.quatinterpbone.triggerindex)

                            for j = 1, bone.quatinterpbone.numtriggers do
                                bone.quatinterpbone.triggers[j] = {
                                    inv_tolerance = _file:ReadFloat(),
                                    trigger       = read_cquat(_file),
                                    pos           = read_cvec(_file),
                                    quat          = read_cquat(_file)
                                }
                            end
                        end

                        _file:Seek(input_pos)
                    elseif bone.proceduralruletype == STUDIO_PROC_TYPE.STUDIO_PROC_AIMATBONE then
                        bone.aimatbone = {
                            parent = _file:ReadLong(),
                            aim    = _file:ReadLong(),

                            aimvector = read_cvec(_file),
                            upvector  = read_cvec(_file),
                            basepos   = read_cvec(_file)
                        }
                    elseif bone.proceduralruletype == STUDIO_PROC_TYPE.STUDIO_PROC_JIGGLE then
                        bone.jigglebone = {
                            flags   = _file:ReadLong(),
                            length  = _file:ReadFloat(),
                            tipMass = _file:ReadFloat(),

                            yawStiffness   = _file:ReadFloat(),
                            yawDamping     = _file:ReadFloat(),
                            pitchStiffness = _file:ReadFloat(),
                            pitchDamping   = _file:ReadFloat(),
                            alongStiffness = _file:ReadFloat(),
                            alongDamping   = _file:ReadFloat(),

                            angleLimit = _file:ReadFloat(),

                            minYaw      = _file:ReadFloat(),
                            maxYaw      = _file:ReadFloat(),
                            yawFriction = _file:ReadFloat(),
                            yawBounce   = _file:ReadFloat(),

                            minPitch      = _file:ReadFloat(),
                            maxPitch      = _file:ReadFloat(),
                            pitchFriction = _file:ReadFloat(),
                            pitchBounce   = _file:ReadFloat(),

                            baseMass            = _file:ReadFloat(),
                            baseStiffness       = _file:ReadFloat(),
                            baseDamping         = _file:ReadFloat(),
                            baseMinLeft         = _file:ReadFloat(),
                            baseMaxLeft         = _file:ReadFloat(),
                            baseLeftFriction    = _file:ReadFloat(),
                            baseMinUp           = _file:ReadFloat(),
                            baseMaxUp           = _file:ReadFloat(),
                            baseUpFriction      = _file:ReadFloat(),
                            baseMinForward      = _file:ReadFloat(),
                            baseMaxForward      = _file:ReadFloat(),
                            baseForwardFriction = _file:ReadFloat(),

                            boingImpactSpeed = _file:ReadFloat(),
                            boingImpactAngle = _file:ReadFloat(),
                            boingDampingRate = _file:ReadFloat(),
                            boingFrequency   = _file:ReadFloat(),
                            boingAmplitude   = _file:ReadFloat()
                        }
                    end
                end

                if bone.surfacepropnameindex ~= 0 then
                    _file:Seek(boneinput_pos + bone.surfacepropnameindex)

                    bone.surfacepropname = read_str_nullend(_file)
                else
                    bone.surfacepropname = ""
                end

                _file:Seek(input_pos)

                bones[#bones + 1] = bone
            end

        end

        local bonecontrollers = {}
        if _h.numbonecontrollers > 0 then
            _file:Seek(_h.bonecontrollerindex)

            local bonecontroller
            for i = 1, _h.numbonecontrollers do
                bonecontroller = {}

                bonecontroller.bone = _file:ReadLong()
                bonecontroller.type = _file:ReadLong()

                bonecontroller.start  = _file:ReadFloat()
                bonecontroller["end"] = _file:ReadFloat()

                bonecontroller.rest       = _file:ReadLong()
                bonecontroller.inputfield = _file:ReadLong()

                for j = 1, 8 do
                    bonecontroller[j] = _file:ReadLong()
                end
            end
        end

        local attachments = {}
        if _h.numlocalattachments > 0 then
            _file:Seek(_h.localattachmentindex)

            for i = 1, _h.numlocalattachments do
                local attachmentinput_pos = _file:Tell()

                attachments[i] = {
                    sznameindex = _file:ReadLong(),
                    flags       = _file:ReadLong(),
                    localbone   = _file:ReadLong(),

                    localM11 = _file:ReadFloat(),
                    localM12 = _file:ReadFloat(),
                    localM13 = _file:ReadFloat(),
                    localM14 = _file:ReadFloat(),
                    localM21 = _file:ReadFloat(),
                    localM22 = _file:ReadFloat(),
                    localM23 = _file:ReadFloat(),
                    localM24 = _file:ReadFloat(),
                    localM31 = _file:ReadFloat(),
                    localM32 = _file:ReadFloat(),
                    localM33 = _file:ReadFloat(),
                    localM34 = _file:ReadFloat()
                }

                attachments[i].unused = {}
                for j = 1, 8 do
                    attachments[i].unused[j] = _file:ReadLong()
                end

                local input_pos = _file:Tell()

                if attachments[i].sznameindex ~= 0 then
                    _file:Seek(attachmentinput_pos + attachments[i].sznameindex)

                    attachments[i].name = read_str_nullend(_file)
                else
                    attachments[i].name = ""
                end

                _file:Seek(input_pos)
            end
        end

        local hitboxsets = {}
        if _h.numhitboxsets > 0 then
            _file:Seek(_h.hitboxsetindex)

            for i = 1, _h.numhitboxsets do
                local hitboxsetinput_pos = _file:Tell()

                hitboxsets[i] = {
                    sznameindex = _file:ReadLong(),
                    numhitboxes = _file:ReadLong(),
                    hitboxindex = _file:ReadLong()
                }

                local input_pos = _file:Tell()

                if hitboxsets[i].sznameindex ~= 0 then
                    _file:Seek(hitboxsetinput_pos + hitboxsets[i].sznameindex)

                    hitboxsets[i].name = read_str_nullend(_file)
                else
                    hitboxsets[i].name = ""
                end

                if hitboxsets[i].numhitboxes > 0 then
                    _file:Seek(hitboxsetinput_pos + hitboxsets[i].hitboxindex)

                    hitboxsets[i].hitboxes = {}
                    for j = 1, hitboxsets[i].numhitboxes do
                        hitboxsets[i].hitboxes[j] = {
                            bone              = _file:ReadLong(),
                            group             = _file:ReadLong(),
                            bbmin             = read_cvec(_file),
                            bbmax             = read_cvec(_file),
                            szhitboxnameindex = _file:ReadLong()
                        }

                        hitboxsets[i].hitboxes[j].unused = {}
                        for k = 1, 8 do
                            hitboxsets[i].hitboxes[j].unused[k] = _file:ReadLong()
                        end

                        local input_pos2 = _file:Tell()

                        if hitboxsets[i].hitboxes[j].szhitboxnameindex ~= 0 then
                            _file:Seek(hitboxsetinput_pos + hitboxsets[i].hitboxindex + hitboxsets[i].hitboxes[j].szhitboxnameindex)

                            hitboxsets[i].hitboxes[j].name = read_str_nullend(_file)
                        else
                            hitboxsets[i].hitboxes[j].name = ""
                        end

                        _file:Seek(input_pos2)
                    end
                end

                _file:Seek(input_pos)
            end
        end

        local bonetablebyname = {}
        if _h.bonetablebynameindex ~= 0 and #bones > 0 then
            _file:Seek(_h.bonetablebynameindex)

            for i = 1, _h.numbones do
                bonetablebyname[i] = _file:ReadByte()
            end
        end

        local animdescs = {}
        if _h.numlocalanim > 0 then
            _file:Seek(_h.localanimindex)

            for i = 1, _h.numlocalanim do
                local animinput_pos = _file:Tell()

                animdescs[i] = {}

                animdescs[i].offsetstart = _file:Tell()

                animdescs[i].baseptr       = _file:ReadLong()
                animdescs[i].sznameindex   = _file:ReadLong()
                animdescs[i].fps           = _file:ReadFloat()
                animdescs[i].flags         = _file:ReadLong()
                animdescs[i].numframes     = _file:ReadLong()
                animdescs[i].nummovements  = _file:ReadLong()
                animdescs[i].movementindex = _file:ReadLong()

                animdescs[i].unused = {}

                for j = 1, 6 do
                    animdescs[i].unused[j] = _file:ReadLong()
                end

                animdescs[i].animblock            = _file:ReadLong()
                animdescs[i].animindex            = _file:ReadLong()
                animdescs[i].numikrules           = _file:ReadLong()
                animdescs[i].ikruleindex          = _file:ReadLong()
                animdescs[i].animblockikruleindex = _file:ReadLong()
                animdescs[i].numlocalhierarchy    = _file:ReadLong()
                animdescs[i].localhierarchyindex  = _file:ReadLong()
                animdescs[i].sectionindex         = _file:ReadLong()
                animdescs[i].sectionframes        = _file:ReadLong()
                animdescs[i].zeroframespan        = _file:ReadShort()
                animdescs[i].zeroframecount       = _file:ReadShort()
                animdescs[i].zeroframeindex       = _file:ReadLong()
                animdescs[i].zeroframestalltime   = _file:ReadFloat()

                local input_pos = _file:Tell()

                if animdescs[i].sznameindex ~= 0 then
                    _file:Seek(animinput_pos + animdescs[i].sznameindex)

                    animdescs[i].name = read_str_nullend(_file)

                    if str_startswith(animdescs[i].name, "a_../") or str_startswith(animdescs[i].name, "a_..\\") then
                        animdescs[i].name = str_sub(animdescs[i].name, 6)
                        animdescs[i].name = string.GetPathFromFilename(animdescs[i].name) .. "a_" .. string.GetFileFromFilename(animdescs[i].name)
                    end
                else
                    animdescs[i].name = ""
                end

                if animdescs[i].zeroframespan ~= 0 or animdescs[i].zeroframecount ~= 0 or
                    animdescs[i].zeroframeindex ~= 0 or animdescs[i].zeroframestalltime ~= 0 then
                    -- TODO: this may not be important
                end

                if animdescs[i].nummovements > 0 then
                    _file:Seek(animinput_pos + animdescs[i].movementindex)

                    animdescs[i].movements = {}
                    for j = 1, animdescs[i].nummovements do
                        animdescs[i].movements[j] = {
                            endframe    = _file:ReadLong(),
                            motionflags = _file:ReadLong(),
                            v0          = _file:ReadFloat(),
                            v1          = _file:ReadFloat(),
                            angle       = _file:ReadFloat(),
                            vector      = read_cvec(_file),
                            position    = read_cvec(_file)
                        }
                    end
                end

                _file:Seek(input_pos)
            end

            -- TODO: verify
            local numsections
            local offset
            for i, animdesc in ipairs(animdescs) do
                animdesc.animsections = {}
                animdesc.animsections[#animdesc.animsections + 1] = {}

                if animdesc.sectionindex ~= 0 and animdesc.sectionframes > 0 then
                    _data.sectionframes = animdesc.sectionframes
                    if _data.sectionframes >= animdesc.sectionframes then
                        _data.sectionframes = animdesc.sectionframes - 1
                    end

                    numsections = math.Truncate(animdesc.numframes / animdesc.sectionframes) + 2

                    for sectionindex = 1, numsections - 1 do
                        animdesc.animsections[#animdesc.animsections + 1] = {}
                    end

                    offset = animdesc.offsetstart + animdesc.sectionindex
                    if offset ~= _file:Tell() then
                        _file:Seek(offset)
                    end

                    animdesc.sections = {}
                    for j = 1, numsections do
                        animdesc.sections[j] = {
                            animblock = _file:ReadLong(),
                            animindex = _file:ReadLong()
                        }
                    end
                end
            end

            -- https://github.com/ZeqMacaw/Crowbar/blob/0d46f3b6a694b74453db407c72c12a9685d8eb1d/Crowbar/Core/GameModel/SourceModel44/SourceMdlFile44.vb#L1322
            -- TODO:
            local function read_mdl_anims(_pos, _animdesc, _sectionframes, _sectionindex, lastsectionisbeingread)
                local animsection = _animdesc.animsections

                _file:Seek(_pos)

                local numbones
                if #bones == 0 then
                    numbones = 1
                else
                    numbones = #bones
                end

                for i = 1, numbones do

                end
            end

            -- TODO: verify
            local adjustedanimindex
            local sectionframes
            local animinput_pos
            for i, animdesc in ipairs(animdescs) do
                animinput_pos = _file:Tell()

                if not _data.firstanimdesc and str_sub(animdesc.name, 1, 1) ~= "@" then
                    _data.firstanimdesc = animdesc
                end

                if (animdesc.flags and STUDIO_FRAMEANIM) ~= 0 then
                    -- do nothing
                else
                    if istable(animdesc.sections)and #animdesc.sections > 0 then
                        for j, section in ipairs(animdesc.sections) do
                            if section.animblock == 0 then
                                adjustedanimindex = section.animindex + (animdesc.animindex - animdesc.sections[1].animindex)

                                if j < #animdesc.sections - 1 then
                                    sectionframes = animdesc.sectionframes
                                else
                                    sectionframes = animdesc.numframes - ((#animdesc.sections - 1) * animdesc.sectionframes)
                                end

                                read_mdl_anims(animinput_pos + adjustedanimindex,
                                    animdesc,
                                    sectionframes,
                                    j,
                                    (j >= #animdesc.sections - 1) or (animdesc.numframes == j * animdesc.sectionframes)
                                )
                            end
                        end
                    elseif animdesc.animblock == 0 then
                        read_mdl_anims(animinput_pos + adjustedanimindex, animdesc, animdesc.numframes, 1, true)
                    end
                end

                if _h.version == 44 or animdesc.animblock == 0 then
                    -- Me.ReadMdlIkRules(animInputFileStreamPosition, anAnimationDesc)
                    -- Me.ReadLocalHierarchies(animInputFileStreamPosition, anAnimationDesc)
                end
            end

            -- https://github.com/ZeqMacaw/Crowbar/blob/0d46f3b6a694b74453db407c72c12a9685d8eb1d/Crowbar/Core/GameModel/SourceModel44/SourceModel44.vb#L376
            -- https://github.com/ZeqMacaw/Crowbar/blob/0d46f3b6a694b74453db407c72c12a9685d8eb1d/Crowbar/Core/GameModel/SourceModel44/SourceMdlFile44.vb#L926
            -- TODO:

        end

        _data.bones = bones
        _data.bonecontrollers = bonecontrollers
        _data.attachments = attachments
        _data.hitboxsets = hitboxsets
        _data.bonetablebyname = bonetablebyname

        _file:Close()
        PrintTable({})

        return 
    end

    do
        read_model("models/alyx.mdl")
    end

    --- https://github.com/Tieske/pe-parser/blob/master/src/pe-parser.lua
    -- TODO: Currently, only mdl's header check is implemented
    local function validate_header(_path)
        local _file = file_open(_path, "rb", "GAME")

        if _file:Read(2) == "MZ" then return false end

        _file:Close()

        if str_ext_fromfile(_path) ~= "mdl" then return true end

        local function hext_to_int(_t) return tonumber(str_fmt("0x%x%x%x%x", _t[4], _t[3], _t[2], _t[1])) end

        local studiohdr_t = read_model(_path, true)

        if studiohdr_t.id     ~= 1414743113 then return false end
        if studiohdr_t.length ~= file_size(_path, "GAME")   then return false end

        if not mdl_determinant.versions[studiohdr_t.version] then return false end
        if not studiohdr_t.checksum then return false end
        if not studiohdr_t.name     then return false end

        return true
    end

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

        assert(size <= max_file_size, mstr"Tries to send file larger than 8.75 MB(8750000 bytes decimal), " .. path)
        assert(validate_header(path), mstr"Corrupted or intentionally bad file (header), "                  .. path)

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
            if     abs(e1[3]:Ping() - e2[3]:Ping()) > 20 then return e1[3]:Ping() < e2[3]:Ping()
            elseif e1[4] ~= e2[4]                        then return e1[4] < e2[4] end
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

    local function ctb(_s, _map)
        local _bytes = {}

        for token in str_gmatch(_s, "([%~%^]?[^%~%^%s%c%z])") do
            _bytes[#_bytes + 1] = _map[token]
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

            wgma(path, file.Read(path, "DATA"), uid)

            if not flag_keepobj then file.Delete(path, "DATA") end

            local tlapse = systime() - temp[uid][3]

            print(str_fmt(mstr"took %s recv & build '%s' from %s, avg spd %s/s",
                string.FormattedTime(tlapse, "%02i:%02i:%02i"), path,
                user:SteamID64(), string.NiceSize(file_size(path .. Either(flag_keepobj, "", ".gma"), "DATA") / tlapse)))

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