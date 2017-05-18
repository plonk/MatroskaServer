module Matroska

  class VInt
    attr :bytes

    def initialize(bytes)
      @bytes = bytes
    end

    def unsigned
      zeros = VInt.num_leading_zeros(@bytes[0])
      len = zeros + 1
      value = (0xff & (@bytes[0] << len)) >> len # throw away the first 1
      zeros.times do |i|
        value <<= 8
        value |= @bytes[i+1]
      end
      value
    end


    def name
      case bytes
      when [0x1A,0x45,0xDF,0xA3] then "EBML"
      when [0x18,0x53,0x80,0x67] then "Segment"
      when [0x1F,0x43,0xB6,0x75] then "Cluster"
      when [0xA3] then "SimpleBlock"
      when [0x42,0x86] then "EBMLVersion"
      when [0x42,0xF7] then "EBMLReadVersion"
      when [0x42,0xF2] then "EBMLMaxIDLength"
      when [0x42,0xF3] then "EBMLMaxSizeLength"
      when [0x42,0x82] then "DocType"
      when [0x42,0x87] then "DocTypeVersion"
      when [0x42,0x85] then "DocTypeReadVersion"
      when [0x11,0x4D,0x9B,0x74] then "SeekHead"
      when [0xEC] then "Void"
      when [0x16,0x54,0xAE,0x6B] then "Tracks"
      when [0x12,0x54,0xC3,0x67] then "Tags"
      when [0x15,0x49,0xA9,0x66] then "Info"
      when [0xE7] then "Timecode"
      when [0x1C,0x53,0xBB,0x6B] then "Cues"
      when [0x2A,0xD7,0xB1] then "TimecodeScale"
      when [0x4D,0x80] then "MuxingApp"
      when [0x44,0x89] then "Duration"
      when [0x57,0x41] then "WritingApp"
      when [0x73,0xA4] then "SegmentUID"
      when [0x73,0x73] then "Tag"
      when [0x63,0xC0] then "Targets"
      when [0x67,0xC8] then "SimpleTag"
      when [0x63,0xC5] then "TagTrackUID"
      when [0x44,0x87] then "TagString"
      when [0x45,0xA3] then "TagName"
      when [0x4D,0xBB] then "Seek"
      when [0x53,0xAB] then "SeekID"
      when [0x53,0xAC] then "SeekPosition"
      when [0xAE] then "TrackEntry"
      when [0xD7] then "TrackNumber"
      when [0x73,0xC5] then 'TrackUID'
      when [0x9C] then 'FlagLacing'
      when [0x22,0xB5,0x9C] then 'Language'
      when [0x86] then 'CodecID'
      when [0x83] then 'TrackType'
      when [0x23,0xE3,0x83] then 'DefaultDuration'
      when [0xE0] then 'Video'
      when [0xE1] then 'Audio'
      when [0x63,0xA2] then 'CodecPrivate'
      when [0xBF] then 'CRC-32'
      else
        bytes.map { |b| "[%02X]" % b }.join
      end
    end

    def self.num_leading_zeros(byte)
      return 0 if byte >= 0x80
      return 1 if byte >= 0x40
      return 2 if byte >= 0x20
      return 3 if byte >= 0x10
      return 4 if byte >= 0x08
      return 5 if byte >= 0x04
      return 6 if byte >= 0x02
      return 7 if byte >= 0x01
      return 8
    end

    def self.read(is)
      b = is.getc.ord
      zeros = self.num_leading_zeros(b)
      fail 'bad data' if zeros > 7
      bytes = [b]
      (zeros).times do
        bytes << is.getc.ord
      end
      VInt.new(bytes)
    end
  end

  def master_element?(id)
    case show_id(id)
    when 'EBML',
         'Segment',
         'Cluster',
         'Info',
         'Tags',
         'Tag',
         'Targets',
         'SimpleTag',
         'SeekHead',
         'Seek',
         'Tracks',
         'TrackEntry'
      true
    else
      false
    end
  end
  module_function :master_element?

end
