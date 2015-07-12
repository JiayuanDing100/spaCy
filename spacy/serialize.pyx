from libcpp.vector cimport vector
from libc.stdint cimport uint32_t
from libc.stdint cimport int64_t
from libc.stdint cimport int32_t
from libc.stdint cimport uint64_t

from preshed.maps cimport PreshMap
from murmurhash.mrmr cimport hash64

import numpy

cimport cython


#cdef class Serializer:
#    def __init__(self, Vocab vocab):
#        pass
#
#    def dump(self, Doc tokens, file_):
#        pass
#        # Format
#        # - Total number of bytes in message (32 bit int)
#        # - Words, terminating in an EOL symbol, huffman coded ~12 bits per word
#        # - Spaces ~1 bit per word
#        # - Parse: Huffman coded head offset / dep label / POS tag / entity IOB tag
#        #          combo. ? bits per word. 40 * 80 * 40 * 12 = 1.5m symbol vocab


cdef struct Node:
    float prob
    int32_t left
    int32_t right


cdef struct Code:
    uint64_t bits
    char length


# Note that we're setting the most significant bits here first, when in practice
# we're actually wanting the last bit to be most significant (for Huffman coding,
# anyway).
cdef Code bit_append(Code code, bint bit) nogil:
    cdef uint64_t one = 1
    if bit:
        code.bits |= one << code.length
    else:
        code.bits &= ~(one << code.length)
    code.length += 1
    return code
    

cdef class HuffmanCodec:
    cdef vector[Node] nodes
    cdef vector[Code] codes
    cdef float[:] probs
    cdef PreshMap table
    def __init__(self, symbols, probs):
        self.table = PreshMap()
        cdef bytes symb_str
        cdef uint64_t key
        cdef uint64_t i
        for i, symbol in enumerate(symbols):
            if type(symbol) == unicode or type(symbol) == bytes:
                symb_str = symbol.encode('utf8')
                key = hash64(<unsigned char*>symb_str, len(symb_str), 0)
            else:
                key = int(symbol)
            self.table[key] = i
        self.probs = probs
        self.codes.resize(len(probs))
        for i in range(len(self.codes)):
            self.codes[i].bits = 0
            self.codes[i].length = 0
        populate_nodes(self.nodes, probs)
        cdef Code path
        path.bits = 0
        path.length = 0
        assign_codes(self.nodes, self.codes, len(self.nodes) - 1, path)

    def encode(self, uint64_t[:] sequence):
        cdef vector[bint] bits
        cdef uint64_t symbol
        for symbol in sequence:
            i = <size_t>self.table.get(symbol)
            if i == 0:
                raise Exception("Unseen symbol: %s" % symbol)
            else:
                code = self.codes[i]
            bits.extend(code)
        return bits

    def decode(self, bits):
        symbols = []
        node = self.nodes.back()
        for bit in bits:
            branch = node.right if bit else node.left
            if branch >= 0:
                node = self.nodes.at(branch)
            else:
                symbols.append(-(branch + 1))
                node = self.nodes.back()
        return symbols

    property strings:
        @cython.boundscheck(False)
        @cython.wraparound(False)
        @cython.nonecheck(False)
        def __get__(self):
            output = []
            cdef int i, j
            cdef bytes string
            cdef Code code
            for i in range(self.codes.size()):
                code = self.codes[i]
                string = b'{0:b}'.format(code.bits).rjust(code.length, '0')
                string = string[::-1]
                output.append(string)
            return output


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.nonecheck(False)
cdef int populate_nodes(vector[Node]& nodes, float[:] probs) except -1:
    assert len(probs) >= 3
    cdef int size = len(probs)
    cdef int i = size - 1
    cdef int j = 0
    
    while i >= 0 or (j+1) < nodes.size():
        if i < 0:
            _cover_two_nodes(nodes, j)
            j += 2
        elif j >= nodes.size():
            _cover_two_words(nodes, i, i-1, probs[i] + probs[i-1])
            i -= 2
        elif i >= 1 and (j == nodes.size() or probs[i-1] < nodes[j].prob):
            _cover_two_words(nodes, i, i-1, probs[i] + probs[i-1])
            i -= 2
        elif (j+1) < nodes.size() and nodes[j+1].prob < probs[i]:
            _cover_two_nodes(nodes, j)
            j += 2
        else:
            _cover_one_word_one_node(nodes, j, i, probs[i])
            i -= 1
            j += 1
    return 0

cdef int _cover_two_nodes(vector[Node]& nodes, int j) nogil:
    cdef Node node
    node.left = j
    node.right = j+1
    node.prob = nodes[j].prob + nodes[j+1].prob
    nodes.push_back(node)


cdef int _cover_one_word_one_node(vector[Node]& nodes, int j, int id_, float prob) nogil:
    cdef Node node
    # Encode leaves as negative integers, where the integer is the index of the
    # word in the vocabulary.
    cdef int64_t leaf_id = - <int64_t>(id_ + 1)
    cdef float new_prob = prob + nodes[j].prob
    if prob < nodes[j].prob:
        node.left = leaf_id
        node.right = j
        node.prob = new_prob
    else:
        node.left = j
        node.right = leaf_id
        node.prob = new_prob
    nodes.push_back(node)


cdef int _cover_two_words(vector[Node]& nodes, int id1, int id2, float prob) nogil:
    cdef Node node
    node.left = -(id1+1)
    node.right = -(id2+1)
    node.prob = prob
    nodes.push_back(node)


cdef int assign_codes(vector[Node]& nodes, vector[Code]& codes, int i, Code path) except -1:
    cdef Code left_path = bit_append(path, 0)
    cdef Code right_path = bit_append(path, 1)
    
    # Assign down left branch
    if nodes[i].left >= 0:
        assign_codes(nodes, codes, nodes[i].left, left_path)
    else:
        # Leaf on left
        id_ = -(nodes[i].left + 1)
        codes[id_] = left_path
    # Assign down right branch
    if nodes[i].right >= 0:
        assign_codes(nodes, codes, nodes[i].right, right_path)
    else:
        # Leaf on right
        id_ = -(nodes[i].right + 1)
        codes[id_] = right_path
