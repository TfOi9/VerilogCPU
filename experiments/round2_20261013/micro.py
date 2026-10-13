"""ISA kernels with independently calculated results."""
def addi(rd, rs, imm): return ((imm & 4095)<<20)|(rs<<15)|(rd<<7)|0x13
def lw(rd,rs,imm=0): return ((imm & 4095)<<20)|(rs<<15)|(2<<12)|(rd<<7)|3
def sw(rs,base,imm=0): return (((imm>>5)&127)<<25)|(rs<<20)|(base<<15)|(2<<12)|((imm&31)<<7)|0x23
def bne(rs,rt,offset):
    n=offset & 8191
    return (((n>>12)&1)<<31)|(((n>>5)&63)<<25)|(rt<<20)|(rs<<15)|(1<<12)|(((n>>1)&15)<<8)|(((n>>11)&1)<<7)|0x63

def program(kind):
    if kind in ('rs-pressure', 'mdu-pressure'):
        words = [(2<<12)|(22<<7)|0x37, addi(22,22,0x710), addi(23,0,7), addi(21,0,1000)]
        begin = len(words)*4
        words.append((1<<25)|(23<<20)|(22<<15)|(5<<12)|(5<<7)|0x33)
        if kind == 'rs-pressure':
            words += [addi(6+i%8,5,i+1) for i in range(16)]
            expected = 1444
        else:
            words += [(1<<25)|(23<<20)|(5<<15)|((6+i%8)<<7)|0x33 for i in range(8)]
            expected = 9996
        words += [addi(21,21,-1)]
        words.append(bne(21,0,begin-len(words)*4))
        words += [(0x80000<<12)|(20<<7)|0x37, sw(13,20), 0x6f]
        return words, expected
    words=[addi(r,0,0) for r in range(5,13)]
    words += [(0x10<<12)|(20<<7)|0x37,addi(5,0,7),sw(5,20),lw(5,20),addi(5,0,0),addi(21,0,1000)]
    begin=len(words)*4
    for i in range(32):
        if kind=='dependent-add': words.append(addi(5,5,1))
        elif kind=='independent-add': words.append(addi(5+i%8,5+i%8,1))
        elif kind=='hot-load': words.append(lw(5+i%8,20))
        elif kind=='hot-store': words.append(sw(0,20))
    words.append(addi(21,21,-1))
    words.append(bne(21,0,begin-len(words)*4))
    if kind=='hot-store': words.append(lw(5,20))
    words += [(0x80000<<12)|(20<<7)|0x37,sw(5,20),0x6f]
    expected={'dependent-add':32000,'independent-add':4000,'hot-load':7,'hot-store':0}[kind]
    return words,expected
