--[[--------------------------------------------------------------------------

LuAUR - Lua interface to the ArchLinux User Repository
by Justin Davis <jrcd83@gmail.com>

Adapted from clydes builting AUR code.

--]]--------------------------------------------------------------------------

local yajl = require "yajl"
local http = require "socket.http"
local core = require "luaur.core"
local util = require "luaur.util"

-- CONSTANTS -----------------------------------------------------------------

local VERSION       = "0.01"
local AUR_BASEURI   = "http://aur.archlinux.org"
local AUR_PKGFMT    = AUR_BASEURI .. "/packages/%s/%s.tar.gz"
local AUR_PBFMT     = AUR_BASEURI .. "/packages/%s/%s/PKGBUILD"
local AUR_USERAGENT = "LuAUR/v" .. VERSION

------------------------------------------------------------------------------

-- Copied from "Programming in Lua"
local function each ( tbl )
    local i   = 0
    local max = table.maxn( tbl )
    return function ()
               i = i + 1
               if i <= max then return tbl[i] end
               return nil
           end
end

local function map ( f, tbl )
    local result = {}
    for key, val in pairs( tbl ) do
        result[ key ] = f( val )
    end
    return result
end

LUAUR         = { basepath = "/tmp/luaur" }
LUAUR.__index = LUAUR

function LUAUR:new ( params )
    local obj = params or { }
    setmetatable( obj, LUAUR )
    return obj
end


local VALID_METHOD = { search = true, info = true, msearch = true }

local function aur_rpc_url ( method, arg )
    if not method or not VALID_METHOD[ method ] then
        error( method .. " is not a valid AUR RPC method" )
    end

    return AUR_BASEURI .. "/rpc.php?type=" .. method .. "&arg=" .. arg
end

local NEWKEYNAME_FOR = { Description = "desc",
                         NumVotes    = "votes",
                         CategoryID  = "category",
                         LocationID  = "location",
                         OutOfDate   = "outdated" }
local function aur_rpc_keyname ( key )
    return NEWKEYNAME_FOR[ key ] or key:lower()
end

function LUAUR:info ( name )
    local url     = aur_rpc_url( "info", name )
    local jsontxt = http.request( url )
        or error( "Failed to call info RPC" )

    local keyname, in_results, results = "", false, {}
    local parser = yajl.parser {
        events = { open_object = function ( events )
                                     if keyname == "results" then
                                         in_results = true
                                     end
                                 end,
                   object_key  = function ( events, name )
                                     keyname = aur_rpc_keyname( name )
                                 end,
                   value       = function ( events, value, type )
                                     if keyname == "type" and
                                         value == "error" then
                                         error( "AUR info RPC failed" )
                                     end
                                     if not in_results then return end
                                     if keyname == "outdated" then
                                         value = ( value == "1" )
                                     end
                                     results[ keyname ] = value
                                 end
          }}

    if not pcall( function () parser( jsontxt ) end ) then return nil end
    return results
end

function LUAUR:search ( query )
    -- Allow search queries to contain regexp anchors... only!
    local regexp
    if query:match( "^^" ) or query:match( "$$" ) then
        regexp = query
        regexp = regexp:gsub("([().%+*?[-])", "%%%1")
        query  = query:gsub( "^^", "" )
        query  = query:gsub( "$$", "" )
    end

    local url     = aur_rpc_url( "search", query )
    local jsontxt = http.request( url )
    if not jsontxt then
        error( "Failed to search AUR using RPC" )
    end

    --[[ Create a custom JSON SAX parser. On results with ~1k entries
         yajl.to_value was bugging out. This is more efficient anyways.
         We can insert values into our results directly... ]]--

    local results     = {}

    local in_results, in_pkg, pkgkey, pkginfo = false, false, "", {}
    local parser = yajl.parser {
        events = { open_array  = function ( evts )
                                     in_results = true
                                 end,
                   open_object = function ( evts )
                                     if in_results then in_pkg = true end
                                 end,
                   close       = function ( evts, type )
                                     if type == "array" and in_results then
                                         in_results = false
                                     elseif type == "object" and in_pkg then
                                         in_pkg  = false
                                         -- Prepare pkginfo for a new
                                         -- package JSON-object entry
                                         pkginfo = {}
                                     end
                                 end,
                   object_key  = function ( evts, name )
                                     if not in_pkg then return end
                                     pkgkey = aur_rpc_keyname( name )
                                 end,
                   -- I think AUR does only string datatypes... heh
                   value       = function ( evts, value, type )
                                     if not in_pkg then return end
                                     if pkgkey == "name" then
                                         results[ value ] = pkginfo
                                     elseif pkgkey == "outdated" then
                                         value = ( value == "1" )
                                     end

                                     pkginfo[ pkgkey ] = value
                                 end
           } }

    parser( jsontxt )

    if not regexp then return results end

    -- Filter out results if regexp-anchors were given
    for name, info in pairs( results ) do
        if not name:match( regexp ) then
            results[ name ] = nil
        end
    end
    return results
end

function LUAUR:get ( package )
    local pkg = LUAURPackage:new { basepath = self.basepath,
                                   dlpath   = self.dlpath,
                                   extpath  = self.extpath,
                                   destpath = self.destpath,
                                   proxy    = self.proxy,
                                   name     = package }

    -- We want to test if the package really exists...
    if not pkg:download_size() then return nil end
    return pkg
end

------------------------------------------------------------------------------

local PKGBUILD_FIELDS = { "pkgname", "pkgver", "pkgrel", "pkgdesc",
                          "url", "license", "install", "changelog", "source",
                          "noextract", "md5sums",
                          "sha1sums", "sha256sums", "sha384sums", "sha512sums",
                          "groups", "arch", "backup", "depends", "makedepends",
                          "optdepends", "conflicts", "provides", "replaces",
                          "options" }

local IS_PKGBUILD_FIELD = {}
for i, field in ipairs( PKGBUILD_FIELDS ) do
    IS_PKGBUILD_FIELD[ field ] = true
end

LUAURPackage = { }

local function pkgbuild_index ( obj, field_name )
    local field_value = rawget( obj, field_name )
    if field_value ~= nil then
        return field_value
    end

    if IS_PKGBUILD_FIELD[ field_name ] then
        local pkgbuild = obj:get_pkgbuild()
        return pkgbuild[ field_name ]
    end

    return LUAURPackage[ field_name ]
end

LUAURPackage.__index = pkgbuild_index

function LUAURPackage:new ( params )
    params = params or { }
    assert( params.name, "Parameter 'name' must be specified" )
    assert( ( params.dlpath and params.extpath and params.destpath )
            or params.basepath, [[
Parameter 'basepath' must be specified unless all other paths are provided
]] )

    local dlpath   = params.dlpath   or params.basepath .. "/src"
    local extpath  = params.extpath  or params.basepath .. "/build"
    local destpath = params.destpath or params.basepath .. "/cache"

    local obj    = params
    obj.pkgfile  = obj.name .. ".src.tar.gz"
    obj.dlpath   = dlpath
    obj.extpath  = extpath
    obj.destpath = destpath

    setmetatable( obj, self )
    return obj
end

function LUAURPackage:download_url ( )
    return string.format( AUR_PKGFMT, self.name, self.name )
end

function LUAURPackage:download_size ( )
    if self.dlsize then return self.dlsize end
    
    USERAGENT = AUR_USERAGENT
    local pkgurl = self:download_url()
    local good, status, headers
        = http.request{ url = pkgurl, method = "HEAD", proxy = self.proxy }

    if not good or status ~= 200 then
        return nil
    end

    self.dlsize = tonumber( headers[ "content-length" ] )
    return self.dlsize
end

function LUAURPackage:download ( callback )
    if self.tgzpath then return self.tgzpath end

    local pkgurl  = self:download_url()
    local pkgpath = self.dlpath .. "/" .. self.pkgfile

    -- Make sure the destination directory exists...
    rec_mkdir( self.dlpath )

    local pkgfile, err = io.open( pkgpath, "wb" )
    assert( pkgfile, err )

    local dlsink = ltn12.sink.file( pkgfile )

    -- If a callback is provided, call it with the download progress...
    if callback then
        if type(callback) ~= "function" then
            error( "Argument to download method must be a callback func" )
        end

        local current, total = 0, self:download_size()
        local dlfilter = function ( dlchunk )
                             if dlchunk == nil or #dlchunk == 0 then
                                 return dlchunk
                             end
                             current = current + #dlchunk
                             callback( current, total )
                             return dlchunk
                         end
        dlsink = ltn12.sink.chain( dlfilter, dlsink )
    end

    USERAGENT = AUR_USERAGENT
    local good, status = http.request { url    = pkgurl,
                                        proxy  = self.proxy,
                                        sink   = dlsink }

    if not good or status ~= 200 then
        local err
        if status ~= 200 then
            err = "HTTP error status " .. status
        else
            err = status
        end
        error( string.format( "Failed to download %s: %s", pkgurl, err ))
    end

    self.tgzpath = pkgpath
    return pkgpath
end

function LUAURPackage:extract ( destdir )
    local pkgpath = self:download()

    -- Do not extract files redundantly...
    if self.pkgdir then return self.pkgdir end

    if destdir == nil then
        destdir = self.extpath
    else
        destdir:gsub( "/+$", "" )
    end

    rec_mkdir( destdir )
    local cmd = string.format( "bsdtar -zxf %s -C %s", pkgpath, destdir )
    local ret = os.execute( cmd )
    if ret ~= 0 then
        error( string.format( "bsdtar returned error code %d", ret ))
    end

    self.pkgdir = destdir .. "/" .. self.name
    return self.pkgdir
end

local function unquote_bash ( quoted_text )
    -- Convert bash arrays (surrounded by parens) into tables
    local noparen, subcount = quoted_text:gsub( "^%((.+)%)$", "%1" )
    if subcount > 0 then
        local wordlist = {}
        for word in noparen:gmatch( "(%S+)" ) do
            table.insert( wordlist, unquote_bash( word ))
        end
        return wordlist
    end

    -- Remove double or single quotes from bash strings
    local text = quoted_text
    text = text:gsub( '^"(.+)"$', "%1" )
    text = text:gsub( "^'(.+)'$", "%1" )
    return text
end

local function pkgbuild_fields ( text )
    local results = {}

    -- First find all fields without quoting characters...
    for name, value in text:gmatch( "([%l%d]+)=(%w%S*)" ) do
        results[ name ] = value
    end

    -- Now handle all quoted field values...
    local quoters = { '""', "''", "()" }
    local fmt     = '([%%l%%d]+)=(%%b%s)'

    for i, quotes in ipairs( quoters ) do
        local regexp = string.format( fmt, quotes )
        for name, value in text:gmatch( regexp ) do
            results[ name ] = unquote_bash( value )
        end
    end

    return results
end

function LUAURPackage:_download_pkgbuild ( )
    local name        = self.name
    local pkgbuildurl = string.format( AUR_PBFMT, name, name )

    local pkgbuildtxt, code = http.request( pkgbuildurl )
    if not pkgbuildtxt or code ~= 200 then
        error( "Failed to download PKGBUILD for " .. name )
    end
    return pkgbuildtxt
end

function LUAURPackage:_extracted_pkgbuild ( )
    local pbpath       = self.pkgdir .. "/PKGBUILD"
    local pbfile, err  = io.open( pbpath, "r" )
    assert( pbfile, err )
    local pbtext       = pbfile:read( "*a" )
    pbfile:close()
    return pbtext
end

local function _smart_deptbl ( depstr )
    if depstr:match( "^[%l%d_-]+$" ) then
        return { package = depstr, cmp = '>', version = 0, str = depstr }
    end

    local pkg, cmp, ver
        = depstr:match( "^([%l%d_-]+)([=<>]=?)([%l%d._-]+)$" )

    assert( pkg and cmp and ver,
            "failed to parse depends string: " .. depstr )

    return { package = pkg, cmp = cmp, version = ver, str = depstr }
end

-- Downloads, extracts tarball (if needed) and then parses the PKGBUILD...
function LUAURPackage:get_pkgbuild ( )
    if self.pkgbuild_info then return self.pkgbuild_info end

    local pbtext
    if self.pkgdir then
        pbtext = self:_extracted_pkgbuild()
    else
        pbtext = self:_download_pkgbuild()
    end

    local pbinfo = pkgbuild_fields( pbtext )

    if pbinfo.depends then
        pbinfo.depends = map( _smart_deptbl, pbinfo.depends )
    else
        pbinfo.depends = {}
    end

    if not pbinfo.conflicts then pbinfo.conflicts = {} end

    self.pkgbuild_info = pbinfo
    return self.pkgbuild_info
end

function LUAURPackage:_builtpkg_path ( pkgdest )
    local pkgbuild = self:get_pkgbuild()
    local arch     = pkgbuild.arch
    if ( type( arch ) == "table" or arch ~= "any" ) then
        arch = core.arch()
    end
    
    local destfile = string.format( "%s/%s-%s-%d-%s.pkg.tar.xz",
                                    pkgdest, self.name,
                                    pkgbuild.pkgver,
                                    pkgbuild.pkgrel,
                                    arch )
    return destfile
end

function LUAURPackage:build ( params )
    if self.pkgpath then return self.pkgpath end

    params = params or {}
    local extdir = self:extract( params.buildbase )

    local pkgdest = params.pkgdest
    if pkgdest == nil then
        pkgdest = self.destpath
    else
        pkgdest:gsub( "/+$", "" )
    end
    pkgdest = absdir( pkgdest )

    local destfile = self:_builtpkg_path( pkgdest )
    local testfile = io.open( destfile, "r" )
    if testfile then
        testfile:close()

        -- Use an already created pkgfile if given the 'usecached' param.
        if params.usecached then
            self.pkgpath = destfile
            return destfile
        end
    end

    rec_mkdir( pkgdest)
    local oldir    = chdir( extdir )

    local cmd = "makepkg"
    if params.prefix then cmd = params.prefix .. " " .. cmd end
    if params.args   then cmd = cmd .. " " .. params.args   end

    -- TODO: restore this env variable afterwards
    core.setenv( "PKGDEST", pkgdest )

    local retval = os.execute( cmd )
    if ( retval ~= 0 ) then
        error( "makepkg returned error code " .. retval )
    end

    chdir( oldir )

    -- Make sure the .pkg.tar.gz file was created...
    assert( io.open( destfile, "r" ))

    self.pkgpath = destfile
    return destfile
end
