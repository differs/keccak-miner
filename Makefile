NVCC=nvcc
LDFLAGS=-Xcompiler="-pthread" -lcurand
CUDAFLAGS=-dc
SOURCES=main.cu
OBJECTS=$(SOURCES:.cu=.o)
EXECUTABLE=keccak_linux

all: $(EXECUTABLE)

$(EXECUTABLE): $(OBJECTS)
        $(NVCC) $(OBJECTS) $(LDFLAGS) -o $@

%.o:    %.cu
        $(NVCC) $(CUDAFLAGS) $< -o $@

clean:
        rm -f test *.o $(EXECUTABLE) 
