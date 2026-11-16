import struct, sys, os

def ppm_to_png(inp, outp):
    with open(inp,'rb') as f:
        data=f.read()
    # parse P6 header
    assert data[:2]==b'P6', data[:2]
    pos=2
    def token():
        nonlocal pos
        while data[pos:pos+1] in (b' ',b'\n',b'\r',b'\t'):
            pos+=1
        s=pos
        while data[pos:pos+1] not in (b' ',b'\n',b'\r',b'\t'):
            pos+=1
        return data[s:pos]
    w=int(token()); h=int(token()); mx=int(token())
    pos+=1  # single whitespace after maxval
    pix=data[pos:pos+w*h*3]
    assert mx==255

    # Build PNG manually: filter byte 0 per row, then zlib (no stdlib zlib? use zlib)
    import zlib
    raw=bytearray()
    stride=w*3
    for y in range(h):
        raw.append(0)
        raw += pix[y*stride:(y+1)*stride]
    comp=zlib.compress(bytes(raw),9)

    def chunk(typ, body):
        c=struct.pack('>I',len(body))+typ+body
        c+=struct.pack('>I', zlib.crc32(typ+body) & 0xffffffff)
        return c

    ihdr=struct.pack('>IIBBBBB', w,h,8,2,0,0,0)
    png=b'\x89PNG\r\n\x1a\n'
    png+=chunk(b'IHDR', ihdr)
    png+=chunk(b'IDAT', comp)
    png+=chunk(b'IEND', b'')
    with open(outp,'wb') as f:
        f.write(png)
    print(f"{os.path.basename(inp)} -> {os.path.basename(outp)} {w}x{h}")

if __name__=='__main__':
    ppm_to_png(sys.argv[1], sys.argv[2])
