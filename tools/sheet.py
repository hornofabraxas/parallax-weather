import zlib,struct,sys
def readpng(p):
    d=open(p,'rb').read();i=8;idat=b''
    while i<len(d):
        l=struct.unpack('>I',d[i:i+4])[0];t=d[i+4:i+8];c=d[i+8:i+8+l];i+=12+l
        if t==b'IHDR':w,h,bd,ct=struct.unpack('>IIBB',c[:10])
        elif t==b'IDAT':idat+=c
    raw=zlib.decompress(idat);bpp={2:3,6:4}[ct];stride=w*bpp;rows=[];prev=bytearray(stride);o=0
    for y in range(h):
        f=raw[o];o+=1;line=bytearray(raw[o:o+stride]);o+=stride
        for x in range(stride):
            a=line[x-bpp] if x>=bpp else 0;b=prev[x];c=prev[x-bpp] if x>=bpp else 0
            if f==1:line[x]=(line[x]+a)&255
            elif f==2:line[x]=(line[x]+b)&255
            elif f==3:line[x]=(line[x]+(a+b)//2)&255
            elif f==4:
                pa=abs(b-c);pb=abs(a-c);pc=abs(a+b-2*c);line[x]=(line[x]+(a if pa<=pb and pa<=pc else b if pb<=pc else c))&255
        rows.append([tuple(line[x*bpp:x*bpp+3]) for x in range(w)]);prev=line
    return rows
def writepng(p,w,h,rows):
    raw=b''.join(b'\0'+bytes(v for px in r for v in px) for r in rows)
    ch=lambda t,c:struct.pack('>I',len(c))+t+c+struct.pack('>I',zlib.crc32(t+c)&0xffffffff)
    open(p,'wb').write(b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+ch(b'IDAT',zlib.compress(raw,6))+ch(b'IEND',b''))
out=sys.argv[1];S=int(sys.argv[2]);names=sys.argv[3:]
ims=[readpng(n+'_1x.png') for n in names];gap=8;w=200*S;h=228*S;W=len(ims)*(w+gap)-gap
rows=[]
for y in range(h):
    r=[]
    for k,im in enumerate(ims):
        src=im[y//S];r+=[src[x//S] for x in range(w)]
        if k<len(ims)-1:r+=[(40,40,40)]*gap
    rows.append(r)
writepng(out,W,h,rows)
