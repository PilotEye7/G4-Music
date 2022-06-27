namespace Music {

    public static Gst.TagList? parse_gst_tags (File file) {
        FileInputStream? fis = null;
        try {
            fis = file.read ();
        } catch (Error e) {
            return null;
        }

        Gst.TagList? tags = null;
        var stream = new BufferedInputStream ((!)fis);
        var head = new uint8[16];

        //  Parse and merge all the leading tags as possible
        while (true) {
            try {
                read_full (stream, head);
                //  Try parse start tag: ID3v2 or APE
                if (Memory.cmp (head, "ID3", 3) == 0) {
                    var buffer = Gst.Buffer.new_wrapped_full (0, head, 0, head.length, null);
                    var size = Gst.Tag.get_id3v2_tag_size (buffer);
                    if (size > head.length) {
                        var data = new_uint8_array (size);
                        Memory.copy (data, head, head.length);
                        read_full (stream, data[head.length:]);
                        var buffer2 = Gst.Buffer.new_wrapped_full (0, data, 0, data.length, null);
                        var tags2 = Gst.Tag.List.from_id3v2_tag (buffer2);
                        tags = merge_tags (tags, tags2);
                    }
                } else if (Memory.cmp (head, "APETAGEX", 8) == 0) {
                    seek_full (stream, 0, SeekType.SET);
                    var size = read_uint32_le (head, 12) + 32;
                    var data = new_uint8_array (size);
                    Memory.copy (data, head, head.length);
                    read_full (stream, data[head.length:]);
                    var tags2 = GstExt.ape_demux_parse_tags (data);
                    tags = merge_tags (tags, tags2);
                } else {
                    //  Parse by file container format
                    if (Memory.cmp (head, "fLaC", 4) == 0) {
                        seek_full (stream, - head.length, SeekType.CUR);
                        var tags2 = parse_flac_tags (stream);
                        tags = merge_tags (tags, tags2);
                    }
                    // No ID3v2/APE any more, quit the loop
                    break;
                }
            } catch (Error e) {
                print ("Parse begin tag %s: %s\n", file.get_parse_name (), e.message);
                break;
            }
        }

        if (tags_has_title_or_image (tags)) {
            return tags;
        }

        //  Parse and merge all the ending tags as possible
        try {
            var tags2 = parse_end_tags (stream);
            tags = merge_tags (tags, tags2);
        } catch (Error e) {
            print ("Parse end tag %s: %s\n", file.get_parse_name (), e.message);
        }

        if (tags != null) {
            //  Fast parsing is done, just return
            return tags;
        }

        //  Parse tags by Gstreamer demux/parse, it is slow
        try {
            seek_full (stream, 0, SeekType.SET);
            var demux_name = get_demux_name_by_content (head);
            if (demux_name == null) {
                var uri = file.get_uri ();
                var pos = uri.last_index_of_char ('.');
                var ext = uri.substring (pos + 1);
                demux_name = get_demux_name_by_extension (ext);
            }
            if (demux_name != null) {
                tags = parse_demux_tags (stream, (!)demux_name);
            }
        } catch (Error e) {
            //  print ("Parse demux %s: %s\n", file.get_parse_name (), e.message);
        }
        return tags;
    }

    public static bool tags_has_title_or_image (Gst.TagList? tags) {
        string? title = null;
        Gst.Sample? sample = null;
        return ((tags?.peek_string_index (Gst.Tags.TITLE, 0, out title) ?? false)
            || (tags?.get_sample (Gst.Tags.IMAGE, out sample) ?? false));
    }

    public static uint8[] new_uint8_array (uint size) throws Error {
        if ((int) size <= 0 || size > 0xfffffff) // 28 bits
            throw new IOError.INVALID_ARGUMENT ("invalid size");
        return new uint8[size];
    }

    public static void read_full (BufferedInputStream stream, uint8[] buffer) throws Error {
        size_t bytes = 0;
        if (! stream.read_all (buffer, out bytes) || bytes != buffer.length)
            throw new IOError.FAILED ("read_all");
    }

    public static void seek_full (BufferedInputStream stream, int64 offset, SeekType type) throws Error {
        if (! stream.seek (offset, type))
            throw new IOError.FAILED ("seek");
    }

    public static uint32 read_uint32_be (uint8[] data, uint pos = 0) {
        return data[pos + 3]
            | ((uint32) (data[pos+2]) << 8)
            | ((uint32) (data[pos+1]) << 16)
            | ((uint32) (data[pos]) << 24);
    }

    public static uint32 read_uint32_le (uint8[] data, uint pos = 0) {
        return data[pos]
            | ((uint32) (data[pos+1]) << 8)
            | ((uint32) (data[pos+2]) << 16)
            | ((uint32) (data[pos+3]) << 24);
    }

    public static uint32 read_decimal_uint (uint8[] data) {
        uint32 n = 0;
        for (var i = 0; i < data.length; i++) {
            n = n * 10 + (data[i] - '0');
        }
        return n;
    }

    public static Gst.TagList? merge_tags (Gst.TagList? tags, Gst.TagList? tags2,
                                            Gst.TagMergeMode mode = Gst.TagMergeMode.KEEP) {
        return tags != null ? tags?.merge (tags2, mode) : tags2;
    }

    public static Gst.TagList? parse_end_tags (BufferedInputStream stream) throws Error {
        var apev2_found = false;
        var foot = new uint8[128];
        Gst.TagList? tags = null;
        seek_full (stream, 0, SeekType.END);
        while (true) {
            try {
                //  Try parse end tag: ID3v1 or APE
                seek_full (stream, -128, SeekType.CUR);
                read_full (stream, foot);
                if (Memory.cmp (foot, "TAG", 3) == 0) {
                    var tags2 = Gst.Tag.List.new_from_id3v1 (foot);
                    tags = merge_tags (tags, tags2);
                    //  print ("ID3v1 parsed: %d\n", tags2.n_tags ());
                    seek_full (stream, -128, SeekType.CUR);
                } else if (Memory.cmp (foot[128-32:], "APETAGEX", 8) == 0) {
                    var size = read_uint32_le (foot, 128 - 32 + 12) + 32;
                    seek_full (stream, - (int) size, SeekType.CUR);
                    var data = new_uint8_array (size);
                    read_full (stream, data);
                    var tags2 = GstExt.ape_demux_parse_tags (data);
                    //  APEv2 is better than others, do REPLACE merge
                    tags = merge_tags (tags, tags2, Gst.TagMergeMode.REPLACE);
                    apev2_found = ! tags2.is_empty ();
                    //  print ("APEv2 parsed: %d\n", tags2.n_tags ());
                    seek_full (stream, - (int) size, SeekType.CUR);
                } else if (Memory.cmp (foot[128-9:], "LYRICS200", 9) == 0) {
                    var size = read_decimal_uint (foot[128-15:128-9]);
                    seek_full (stream, - (int) (size + 15), SeekType.CUR);
                    var data = new_uint8_array (size);
                    read_full (stream, data);
                    var tags2 = parse_lyrics200_tags (data);
                    tags = merge_tags (tags, tags2, apev2_found ? Gst.TagMergeMode.KEEP : Gst.TagMergeMode.REPLACE);
                    //  print ("LYRICS200 parsed: %d\n", tags2.n_tags ());
                    seek_full (stream, - (int) (size + 15), SeekType.CUR);
                } else {
                    break;
                }
            } catch (Error e) {
                if (tags == null)
                    throw e;
                break;
            }
        }
        return tags;
    }

    public static Gst.TagList? parse_flac_tags (BufferedInputStream stream) throws Error {
        var head = new uint8[4];
        read_full (stream, head);
        if (Memory.cmp (head, "fLaC", 4) != 0) {
            return null;
        }
        int flags = 0;
        Gst.TagList? tags = null;
        do {
            try {
                read_full (stream, head);
                var type = head[0] & 0x7f;
                var size = ((uint32) (head[1]) << 16) | ((uint32) (head[2]) << 8) | head[3];
                //  print ("FLAC block: %d, %u\n", type, size);
                if (type == 4) {
                    var data = new_uint8_array (size + 4);
                    read_full (stream, data[4:]);
                    head[0] &= (~0x80); // clear the is-last flag
                    Memory.copy (data, head, 4);
                    var tags2 = Gst.Tag.List.from_vorbiscomment (data, head, null);
                    tags = merge_tags (tags, tags2);
                    flags |= 0x01;
                } else if (type == 6) {
                    var data = new_uint8_array (size);
                    read_full (stream, data);
                    uint pos = 0;
                    var img_type = read_uint32_be (data, pos);
                    pos += 4;
                    var img_mimetype_len = read_uint32_be (data, pos);
                    pos += 4 + img_mimetype_len;
                    if (pos + 4 > size) {
                        break;
                    }
                    var img_description_len = read_uint32_be (data, pos);
                    pos += 4 + img_description_len;
                    pos += 4 * 4; // image properties
                    if (pos + 4 > size) {
                        break;
                    }
                    var img_len = read_uint32_be (data, pos);
                    pos += 4;
                    if (pos + img_len > size) {
                        break;
                    }
                    tags = tags ?? new Gst.TagList.empty ();
                    Gst.Tag.List.add_id3_image ((!)tags, data[pos:pos+img_len], img_type);
                    flags |= 0x02;
                } else {
                    seek_full (stream, size, SeekType.CUR);
                }
            } catch (Error e) {
                if (tags == null)
                    throw e;
                break;
            }
        } while ((flags & 0x03) != 0x03);
        return tags;
    }

    public const string[] ID3_TAG_ENCODINGS = {
        "GST_ID3V1_TAG_ENCODING",
        "GST_ID3_TAG_ENCODING",
        "GST_TAG_ENCODING",
        (string) null
    };

    public static Gst.TagList parse_lyrics200_tags (uint8[] data) {
        var tags = new Gst.TagList.empty ();
        if (Memory.cmp (data, "LYRICSBEGIN", 11) != 0) {
            return tags;
        }

        var length = data.length;
        var pos = 11;
        while (pos + 8 < length) {
            var id = data[pos:pos+3];
            pos += 3;
            var len = read_decimal_uint (data[pos:pos+5]);
            pos += 5;
            if (pos + len > length) {
                break;
            }
            var str = data[pos:pos+len];
            pos += (int) len;
            string? tag = null;
            if (Memory.cmp (id, "EAL", 3) == 0) {
                tag = Gst.Tags.ALBUM;
            } else if (Memory.cmp (id, "EAR", 3) == 0) {
                tag = Gst.Tags.ARTIST;
            } else if (Memory.cmp (id, "ETT", 3) == 0) {
                tag = Gst.Tags.TITLE;
            } else if (Memory.cmp (id, "LYR", 3) == 0) {
                tag = Gst.Tags.LYRICS;
            }
            if (tag != null) {
                var value = Gst.Tag.freeform_string_to_utf8 ((char[]) str, ID3_TAG_ENCODINGS);
                if (value.length > 0) {
                    tags.add (Gst.TagMergeMode.APPEND, (!)tag, value);
                }
            }
        }
        return tags;
    }

    public static Gst.TagList? parse_demux_tags (BufferedInputStream stream, string demux_name) throws Error {
        var str = @"giostreamsrc name=src ! $(demux_name) ! fakesink sync=false";
        dynamic Gst.Pipeline? pipeline = Gst.parse_launch (str) as Gst.Pipeline;
        dynamic Gst.Element? src = pipeline?.get_by_name ("src");
        ((!)src).stream = stream;

        if (pipeline?.set_state (Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE) {
            throw new UriError.FAILED ("change state failed");
        }

        var bus = pipeline?.get_bus ();
        bool quit = false;
        Gst.TagList? tags = null;
        do {
            var message = bus?.timed_pop (Gst.SECOND * 5);
            if (message == null)
                break;
            var msg = (!)message;
            switch (msg.type) {
                case Gst.MessageType.TAG:
                    if (tags != null) {
                        Gst.TagList? tags2 = null;
                        msg.parse_tag (out tags2);
                        tags = merge_tags (tags, tags2);
                    } else {
                        msg.parse_tag (out tags);
                    }
                    if (tags_has_title_or_image (tags)) {
                        quit = true;
                    }
                    break;

                case Gst.MessageType.ERROR:
                    Error err;
                    string debug;
                    ((!)msg).parse_error (out err, out debug);
                    print ("Parse error: %s, %s\n", err.message, debug);
                    quit = true;
                    break;

                case Gst.MessageType.EOS:
                    quit = true;
                    break;

                default:
                    break;
            }
        } while (!quit);
        pipeline?.set_state (Gst.State.NULL);
        return tags;
    }

    private static string? get_demux_name_by_content (uint8[] head) {
        uint8* p = head;
        if (Memory.cmp (p, "FORM", 4) == 0 && (Memory.cmp (p + 8, "AIFF", 4) == 0 || Memory.cmp (p + 8, "AIFC", 4) == 0)) {
            return "aiffparse";
        } else if (Memory.cmp (p, "fLaC", 4) == 0) {
            return "flacparse";
        } else if (Memory.cmp (p + 4, "ftyp", 4) == 0) {
            return "qtdemux";
        } else if (Memory.cmp (p, "OggS", 4) == 0) {
            return "oggdemux";
        } else if (Memory.cmp (p, "RIFF", 4) == 0 && Memory.cmp (p + 8, "WAVE", 4) == 0) {
            return "wavparse";
        } else if (Memory.cmp (p, "\x30\x26\xB2\x75\x8E\x66\xCF\x11\xA6\xD9\x00\xAA\x00\x62\xCE\x6C", 16) == 0) {
            return "asfparse";
        }
        return null;
    }

    private static string? get_demux_name_by_extension (string ext_name) {
        var ext = ext_name.down ();
        switch (ext) {
            case "aiff":
                return "aiffparse";
            case "flac":
                return "flacparse";
            case "m4a":
            case "m4b":
            case "mp4":
                return "qtdemux";
            case "ogg":
            case "oga":
                return "oggdemux";
            case "opus":
                return "opusparse";
            case "vorbis":
                return "vorbisparse";
            case "wav":
                return "wavparse";
            case "wma":
                return "asfparse";
            default:
                return null;
        }
    }

    public static Gst.Sample? parse_image_from_tag_list (Gst.TagList tags) {
        Gst.Sample? sample = null;
        if (tags.get_sample (Gst.Tags.IMAGE, out sample)) {
            return sample;
        }
        if (tags.get_sample (Gst.Tags.PREVIEW_IMAGE, out sample)) {
            return sample;
        }

        for (var i = 0; i < tags.n_tags (); i++) {
            var tag = tags.nth_tag_name (i);
            var value = tags.get_value_index (tag, 0);
            sample = null;
            if (value?.type () == typeof (Gst.Sample)
                    && tags.get_sample (tag, out sample)) {
                var caps = sample?.get_caps ();
                if (caps != null) {
                    return sample;
                }
                //  print (@"unknown image tag: $(tag)\n");
            }
        }
        return null;
    }
}
