when not compileOption("gc", "arc") or not compileOption("gc", "orc"):
  {.error: "WizWalker-Nim/wad.nim must be compiled with --gc:arc or --gc:orc".}

import std/tables
import std/memfiles
import std/sets
import std/[strformat, strutils]
import std/os
import std/sequtils
import std/options
import std/streams
import std/threadpool
{.experimental: "parallel".}

import zippy

import ../utils

const wad_no_compress = [".mp3", ".ogg"].toHashSet()

type
  Wad* = object
    path*: string
    name*: string
    file_map: Table[string, WadFileInfo]
    mapped_file: MemFile
    file_ptr: pointer
    size: int
    refreshed_once: bool

  WadRef* = ref Wad

  WadFileInfo* = ref object of RootObj
    name*: string
    offset*: int
    size*: int
    zipped_size*: int
    is_zip*: bool
    crc*: int

proc destroy(self: var Wad) =
  if self.file_ptr != nil:
    self.file_ptr = nil
    self.mapped_file.close()

proc `destroy=`(self: var Wad) =
  self.destroy()

proc close*(self: WadRef) =
  ## Close the file handle. Normally this does not have to be used explicitly
  self[].destroy()

proc init(self: WadRef, path: string) =
  self.path = path
  self.name = path.extractFilename()

proc wadFromGameData*(name: string): WadRef =
  ## Load a Wad from Data/GameData/
  new(result, close)
  let path = &"{getWizInstall().get()}/Data/GameData/{name}.wad"
  result.init(path)

# Puts offset in scope so readWithOffset can use it
template scopeOffset(start: int, body: untyped) {.dirty.} =
  var cur_read_offset = start
  body

# This reads and advances the offset
template readWithOffset[T](p: pointer, t: typedesc[T]): T =
  cur_read_offset += sizeof(T)
  cast[ptr T](cast[ByteAddress](p) + cur_read_offset - sizeof(T))[]

proc refreshJournal(self: WadRef) =
  if self.refreshed_once:
    return

  self.refreshed_once = true

  scopeOffset(5):
    let
      version = self.file_ptr.readWithOffset(int32)
      file_num = self.file_ptr.readWithOffset(int32)
    
    if version >= 2:
      inc cur_read_offset

    for _ in 0 ..< file_num:
      let
        offset = self.file_ptr.readWithOffset(int32)
        size = self.file_ptr.readWithOffset(int32)
        zipped_size = self.file_ptr.readWithOffset(int32)
        is_zip = self.file_ptr.readWithOffset(bool)
        crc = self.file_ptr.readWithOffset(int32)
        name_length = self.file_ptr.readWithOffset(int32)

      var name = newString(name_length)
      copyMem(addr(name[0]), cast[pointer](cast[ByteAddress](self.file_ptr) + cur_read_offset), name_length)
      cur_read_offset += name_length
      name = name.strip(chars={'\x00'})

      self.file_map[name] = WadFileInfo(
        name : name,
        offset : offset,
        size : size,
        zipped_size : zipped_size,
        is_zip : is_zip,
        crc : crc
      )

proc open(self: WadRef) =
  if not (self.file_ptr == nil):
    return

  self.mapped_file = memfiles.open(self.path)
  self.file_ptr = self.mapped_file.mapMem()
  self.refresh_journal()

proc getSize*(self: WadRef): int =
  ## Sets the size of the Wad instance and returns it
  self.open()

  if self.size != 0:
    return self.size

  for f in self.file_map.values():
    result += f.size
  self.size = result

proc nameList*(self: WadRef): seq[string] =
  ## List of all file names in this wad
  self.open()
  result = self.file_map.keys().toSeq()

proc infoList*(self: WadRef): seq[WadFileInfo] =
  ## List of all WadFileInfo in this wad
  self.open()
  result = self.file_map.values().toSeq()

proc getInfo*(self: WadRef, name: string): WadFileInfo = 
  ## Gets WadFileInfo for a named file
  self.open()

  try:
    result = self.file_map[name]
  except KeyError:
    raise newException(ValueError, &"File {name} not found")

proc read(self: WadRef, offset: int, size: int): string =
  self.open()
  result = newString(size)
  copyMem(addr(result[0]), cast[pointer](cast[ByteAddress](self.file_ptr) + offset), size)

proc read*(self: WadRef, name: string): string =
  ## Read a file's contents
  self.open()

  let target_file = self.getInfo(name)

  result =
    if target_file.is_zip:
      self.read(target_file.offset, target_file.zipped_size)
    else:
      self.read(target_file.offset, target_file.size)

  if cast[ptr int32](addr(result[0]))[] == 0:
    return ""

  if target_file.is_zip:
    result = uncompress(result, dfZlib)

proc unpackAll*(self: WadRef, target_path: string) =
  ## Unarchive a wad into target_path
  self.open()
  let path = target_path.strip(chars={'/'}, leading=false).absolutePath()

  var known_dirs: HashSet[string]

  var fileindex: seq[(string, pointer, int, int, bool)]

  for file in self.file_map.values():
    let
      filepath = &"{path}/{file.name}"

    if file.is_zip:
      file_index.add((filepath, self.file_ptr, file.offset, file.zipped_size, true))
    else:
      file_index.add((filepath, self.file_ptr, file.offset, file.size, false))


  # filepath, mem_ptr, start, size, is_zip
  proc worker(v: (string, pointer, int, int, bool)) =
    let dir_path = v[0].parentDir()
    createDir(dir_path)

    var data = newString(v[3])
    copyMem(addr(data[0]), cast[pointer](cast[ByteAddress](v[1]) + v[2]), v[3])
    if v[4]:
      data = uncompress(data, dfZlib)

    var fh = io.open(v[0], fmWrite)
    fh.write(data)
    fh.close()

  parallel:
    for x in fileindex:
      spawn worker(x)
  sync()

when isMainmodule:
  import times

  let root_wad = wadFromGameData("WizardCity-TreasureTower-WC_TT01_Fire_L12")
  let start = cpuTime()
  root_wad.unpackAll("C:/wadtest/WizardCity-TreasureTower-WC_TT01_Fire_L12")
  echo &"Extraction took {cpuTime() - start}s"
