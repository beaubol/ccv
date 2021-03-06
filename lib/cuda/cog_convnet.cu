extern "C" {
#include "cog.h"
}

static inline void _ccv_convnet_compute_output_scale(int a_rows, int a_cols, ccv_convnet_layer_t* layer, int* rows, int* cols)
{
	assert(rows != 0 && cols != 0);
	switch(layer->type)
	{
		case CCV_CONVNET_CONVOLUTIONAL:
			assert(layer->net.convolutional.rows % 2); // as of now, don't support even number of kernel size
			assert(layer->net.convolutional.cols % 2);
			assert((a_rows + layer->net.convolutional.border * 2 - layer->net.convolutional.rows) % layer->net.convolutional.strides == 0);
			assert((a_cols + layer->net.convolutional.border * 2 - layer->net.convolutional.cols) % layer->net.convolutional.strides == 0);
			*rows = (a_rows + layer->net.convolutional.border * 2 - layer->net.convolutional.rows) / layer->net.convolutional.strides + 1;
			*cols = (a_cols + layer->net.convolutional.border * 2 - layer->net.convolutional.cols) / layer->net.convolutional.strides + 1;
			break;
		case CCV_CONVNET_FULL_CONNECT:
			*rows = layer->net.full_connect.count;
			*cols = 1;
			break;
		case CCV_CONVNET_MAX_POOL:
		case CCV_CONVNET_AVERAGE_POOL:
			assert((a_rows - layer->net.pool.size) % layer->net.pool.strides == 0);
			assert((a_cols - layer->net.pool.size) % layer->net.pool.strides == 0);
			*rows = (a_rows - layer->net.pool.size) / layer->net.pool.strides + 1;
			*cols = (a_cols - layer->net.pool.size) / layer->net.pool.strides + 1;
			break;
	}
}

static const int CUDA_FIRST_PASS = 1;
static const int CUDA_LAST_PASS = 2;
static const int CUDA_SINGLE_PASS = 3;

template <int input_per_thread, int filter_per_thread, int pass>
__global__ void _ccv_kern_convolutional_forward_propagate(const int strides, const int border,
		float* input, const int rows, const int cols, const int channels,
		float* out, const int out_rows, const int out_cols,
		float* const filter, const int filter_rows, const int filter_cols, const int count,
		float* const biases)
{
	// gridDim.x == out_rows
	// gridDim.y == out_cols
	extern __shared__ float shared[];
	float* shared_block = &shared[0];
	const int batch = input_per_thread * blockDim.x;
	float* shared_weights = &shared[batch];
	float* shared_bias = &shared[batch + count];
	float prod[filter_per_thread][input_per_thread];
	const int thidx = threadIdx.x + threadIdx.y * blockDim.x;
	const int thcnt = blockDim.x * blockDim.y;
	const int input_loads = (batch + thcnt - 1) / thcnt;
	const int filter_loads = (count + thcnt - 1) / thcnt;
	int i, j, x, y;
	#pragma unroll
	for (i = 0; i < filter_per_thread; i++)
		#pragma unroll
		for (j = 0; j < input_per_thread; j++)
			prod[i][j] = 0;
	input += (blockIdx.x * strides * cols + blockIdx.y * strides) * batch;
	if (pass == CUDA_SINGLE_PASS || pass == CUDA_FIRST_PASS)
		for (i = 0; i < filter_loads; i++)
			if (i * thcnt + thidx < count)
				shared_bias[i * thcnt + thidx] = biases[i * thcnt + thidx];
	for (y = 0; y < filter_rows; y++)
	{
		const int iy = y + blockIdx.x * strides - border;
		for (x = 0; x < filter_cols; x++)
		{
			const int ix = x + blockIdx.y * strides - border;
			if (iy >= 0 && iy < rows && ix >= 0 && ix < cols)
			{
				for (i = 0; i < input_loads; i++)
					if (i * thcnt + thidx < batch)
						shared_block[i * thcnt + thidx] = input[((y - border) * cols + x - border) * batch + i * thcnt + thidx];
				for (i = 0; i < filter_loads; i++)
					if (i * thcnt + thidx < count)
						shared_weights[i * thcnt + thidx] = filter[(y * filter_cols + x) * count + i * thcnt + thidx];
				__syncthreads();
				#pragma unroll
				for (i = 0; i < filter_per_thread; i++)
					#pragma unroll
					for (j = 0; j < input_per_thread; j++)
						prod[i][j] += shared_block[j + threadIdx.x * input_per_thread] * shared_weights[i + threadIdx.y * filter_per_thread];
				__syncthreads();
			}
		}
	}
	const int outcnt = out_rows * out_cols * batch;
	out += (blockIdx.x * out_cols + blockIdx.y) * batch;
	switch (pass)
	{
		case CUDA_SINGLE_PASS:
			#pragma unroll
			for (i = 0; i < filter_per_thread; i++)
			{
				const float bias = shared_bias[i + threadIdx.y * filter_per_thread];
				#pragma unroll
				for (j = 0; j < input_per_thread; j++)
					out[(i + threadIdx.y * filter_per_thread) * outcnt + j + threadIdx.x * input_per_thread] = max(0.0, prod[i][j] + bias);
			}
			break;
		case CUDA_FIRST_PASS:
			#pragma unroll
			for (i = 0; i < filter_per_thread; i++)
			{
				const float bias = shared_bias[i + threadIdx.y * filter_per_thread];
				#pragma unroll
				for (j = 0; j < input_per_thread; j++)
					out[(i + threadIdx.y * filter_per_thread) * outcnt + j + threadIdx.x * input_per_thread] = prod[i][j] + bias;
			}
			break;
		case CUDA_LAST_PASS:
			#pragma unroll
			for (i = 0; i < filter_per_thread; i++)
				#pragma unroll
				for (j = 0; j < input_per_thread; j++)
					out[(i + threadIdx.y * filter_per_thread) * outcnt + j + threadIdx.x * input_per_thread] = max(0.0, out[(i + threadIdx.y * filter_per_thread) * outcnt + j + threadIdx.x * input_per_thread] + prod[i][j]);
			break;
		default:
			#pragma unroll
			for (i = 0; i < filter_per_thread; i++)
				#pragma unroll
				for (j = 0; j < input_per_thread; j++)
					out[(i + threadIdx.y * filter_per_thread) * outcnt + j + threadIdx.x * input_per_thread] += prod[i][j];
			break;
	}
}
/*
template <int input_per_thread, int filter_per_thread, int pass>
__global__ void _ccv_kern_convolutional_backward_propagate(const int strides, const int border,
		float* input, const int out_rows, const int out_cols,
		float* out, const int rows, const int cols, const int channels,
		float* filter, const int filter_rows, const int filter_cols, const int count)
{
	// gridDim.x == out_rows
	// gridDim.y == out_cols
	extern __shared__ float shared[];
	float* shared_block = &shared[0];
	const int batch = input_per_thread * blockDim.x;
	float* shared_weights = &shared[batch];
	float prod[filter_per_thread][input_per_thread];
	const int thidx = threadIdx.x + threadIdx.y * blockDim.x;
	const int thcnt = blockDim.x * blockDim.y;
	const int out_loads = (batch + thcnt - 1) / thcnt;
	const int filter_loads = (count + thcnt - 1) / thcnt;
}
*/
#include <sys/time.h>
#include <ctype.h>

static unsigned int get_current_time(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

static void _cog_convolutional_forward_propagate(ccv_convnet_layer_t* layer, int batch, int rows, int cols, int ch, float* a, float* d, float** b)
{
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);
	cudaEventRecord(start, 0);
	int out_rows, out_cols;
	_ccv_convnet_compute_output_scale(rows, cols, layer, &out_rows, &out_cols);
	assert(b);
	float* db = *b;
	if (!db)
		cudaMalloc(&db, sizeof(float) * out_rows * out_cols * layer->net.convolutional.count * batch);
	*b = db;
	float* od_w = 0;
	cudaMalloc(&od_w, sizeof(float) * (layer->wnum + layer->net.convolutional.count));
	cudaMemcpy(od_w, layer->w, sizeof(float) * (layer->wnum + layer->net.convolutional.count), cudaMemcpyHostToDevice);
	dim3 threads_per_block(batch / 8, layer->net.convolutional.count / 4);
	dim3 num_blocks(out_rows, out_cols);
	int shared_memory_size = sizeof(float) * (batch + layer->net.convolutional.count);
	if (ch > 1)
	{
		_ccv_kern_convolutional_forward_propagate
			<8, 4, CUDA_FIRST_PASS>
			<<<num_blocks, threads_per_block, shared_memory_size + /* need extra space for bias */ sizeof(float) * layer->net.convolutional.count>>>
			(layer->net.convolutional.strides, layer->net.convolutional.border,
			 a, rows, cols, ch,
			 db, out_rows, out_cols,
			 od_w, layer->net.convolutional.rows, layer->net.convolutional.cols, layer->net.convolutional.count,
			 od_w + layer->wnum);
		int i;
		for (i = 1; i < ch - 1; i++)
			_ccv_kern_convolutional_forward_propagate
				<8, 4, 0>
				<<<num_blocks, threads_per_block, shared_memory_size>>>
				(layer->net.convolutional.strides, layer->net.convolutional.border,
				 a + i * batch * rows * cols, rows, cols, ch,
				 db, out_rows, out_cols,
				 od_w + i * layer->net.convolutional.rows * layer->net.convolutional.cols, layer->net.convolutional.rows, layer->net.convolutional.cols, layer->net.convolutional.count,
				 od_w + layer->wnum);
		_ccv_kern_convolutional_forward_propagate
			<8, 4, CUDA_LAST_PASS>
			<<<num_blocks, threads_per_block, shared_memory_size>>>
			(layer->net.convolutional.strides, layer->net.convolutional.border,
			 a + (ch - 1) * batch * rows * cols, rows, cols, ch,
			 db, out_rows, out_cols,
			 od_w + (ch - 1) * layer->net.convolutional.rows * layer->net.convolutional.cols, layer->net.convolutional.rows, layer->net.convolutional.cols, layer->net.convolutional.count,
			 od_w + layer->wnum);
	} else {
		_ccv_kern_convolutional_forward_propagate
			<8, 4, CUDA_SINGLE_PASS>
			<<<num_blocks, threads_per_block, shared_memory_size + /* need extra space for bias */ sizeof(float) * layer->net.convolutional.count>>>
			(layer->net.convolutional.strides, layer->net.convolutional.border,
			 a, rows, cols, ch,
			 db, out_rows, out_cols,
			 od_w, layer->net.convolutional.rows, layer->net.convolutional.cols, layer->net.convolutional.count,
			 od_w + layer->wnum);
	}
	cudaEventRecord(stop, 0);
	cudaEventSynchronize(stop);
	float elapsed_time;
	cudaEventElapsedTime(&elapsed_time, start, stop);
	cudaEventDestroy(start);
	cudaEventDestroy(stop);
	printf("cuda elapsed time: %.2lf\n", elapsed_time);
}

static void _ccv_convnet_convolutional_forward_propagate(ccv_convnet_layer_t* layer, ccv_dense_matrix_t* a, ccv_dense_matrix_t* d, ccv_dense_matrix_t** b)
{
	int rows, cols;
	_ccv_convnet_compute_output_scale(a->rows, a->cols, layer, &rows, &cols);
	int ch = layer->net.convolutional.channels;
	int count = layer->net.convolutional.count;
	int strides = layer->net.convolutional.strides;
	int border = layer->net.convolutional.border;
	int kernel_rows = layer->net.convolutional.rows;
	int kernel_cols = layer->net.convolutional.cols;
	int type = CCV_32F | count;
	assert(CCV_GET_CHANNEL(a->type) == ch);
	assert(CCV_GET_DATA_TYPE(a->type) == CCV_32F);
	ccv_dense_matrix_t* db = *b = ccv_dense_matrix_renew(*b, rows, cols, type, type, 0);
	int i, j, x, y, k;
#define for_block(act_block_setup, act_block_begin, act_block_end) \
	for (k = 0; k < count; k++) \
	{ \
		float* ap = a->data.f32; \
		float* bp = db->data.f32 + k; \
		float* layer_w = layer->w + k * kernel_rows * kernel_cols * ch; \
		float bias = layer->bias[k]; \
		act_block_setup; \
		for (i = 0; i < db->rows; i++) \
		{ \
			int comy = ccv_max(i * strides - border, 0) - (i * strides - border); \
			int maxy = kernel_rows - comy - (i * strides + kernel_rows - ccv_min(a->rows + border, i * strides + kernel_rows)); \
			comy *= ch * kernel_cols; \
			for (j = 0; j < db->cols; j++) \
			{ \
				act_block_begin; \
				float v = bias; \
				int comx = (ccv_max(j * strides - border, 0) - (j * strides - border)) * ch; \
				int maxx = kernel_cols * ch - comx - (j * strides + kernel_cols - ccv_min(a->cols + border, j * strides + kernel_cols)) * ch; \
				float* w = layer_w + comx + comy; \
				float* apz = ap + ccv_max(j * strides - border, 0) * ch; \
				/* when we have border, we simply do zero padding */ \
				for (y = 0; y < maxy; y++) \
				{ \
					for (x = 0; x < maxx; x++) \
						v += w[x] * apz[x]; \
					w += kernel_cols * ch; \
					apz += a->cols * ch; \
				} \
				bp[j * count] = ccv_max(0, v) /* ReLU */; \
				act_block_end; \
			} \
			bp += db->cols * count; \
			ap += a->cols * ch * (ccv_max((i + 1) * strides - border, 0) - ccv_max(i * strides - border, 0)); \
		} \
	}
	if (d)
	{
#define act_block_setup \
		int* dp = d->data.i32 + k;
#define act_block_begin \
		if (!*dp) \
		{
#define act_block_end \
		} else \
			bp[j * count] = 0; \
		dp += count;
		for_block(act_block_setup, act_block_begin, act_block_end);
#undef act_block_setup
#undef act_block_begin
#undef act_block_end
	} else {
		for_block(/* empty act block setup */, /* empty act block begin */, /* empty act block end */);
	}
#undef for_block
}

void cog_convnet_encode(ccv_convnet_t* convnet, ccv_dense_matrix_t** a, ccv_dense_matrix_t** b, int batch)
{
	int ch = CCV_GET_CHANNEL(a[0]->type);
	int rows = a[0]->rows, cols = a[0]->cols;
	float* vec = 0;
	cudaMallocHost(&vec, sizeof(float) * batch * rows * cols * ch);
	int i, j, k;
	for (i = 0; i < batch; i++)
		for (k = 0; k < ch; k++)
			for (j = 0; j < rows * cols; j++)
				vec[i + (k * rows * cols + j) * batch] = a[i]->data.f32[j * ch + k];
	float* od_vec = 0;
	cudaMalloc(&od_vec, sizeof(float) * batch * rows * cols * ch);
	cudaMemcpy(od_vec, vec, sizeof(float) * batch * rows * cols * ch, cudaMemcpyHostToDevice);
	float* od_out = 0;
	_cog_convolutional_forward_propagate(convnet->layers, batch, rows, cols, ch, od_vec, 0, &od_out);
	int out_rows, out_cols;
	_ccv_convnet_compute_output_scale(rows, cols, convnet->layers, &out_rows, &out_cols);
	float* out = 0;
	cudaMallocHost(&out, sizeof(float) * batch * out_rows * out_cols * convnet->layers->net.convolutional.count);
	cudaMemcpy(out, od_out, sizeof(float) * batch * out_rows * out_cols * convnet->layers->net.convolutional.count, cudaMemcpyDeviceToHost);
	unsigned int elapsed_time = get_current_time();
	for (i = 0; i < batch; i++)
	{
		ccv_dense_matrix_t* b = 0;
		_ccv_convnet_convolutional_forward_propagate(convnet->layers, a[i], 0, &b);
		int x, y, ch = convnet->layers->net.convolutional.count;
		for (k = 0; k < ch; k++)
			for (y = 0; y < b->rows; y++)
				for (x = 0; x < b->cols; x++)
				{
					float delta = fabsf(out[k * out_rows * out_cols * batch + (x + y * out_cols) * batch + i] - b->data.f32[(x + y * out_cols) * ch + k]);
					if (delta > 1e-2)
						printf("%d %d %d %g %g\n", i, x, y, out[k * out_rows * out_cols * batch + (x + y * out_cols) * batch + i], b->data.f32[(x + y * out_cols) * ch + k]);
				}
		ccv_matrix_free(b);
	}
	elapsed_time = get_current_time() - elapsed_time;
	printf("cpu elapsed time: %u\n", elapsed_time);
}

void cog_convnet_classify(ccv_convnet_t* convnet, ccv_dense_matrix_t** a, int* labels, int batch)
{
}

void cog_convnet_supervised_train(ccv_convnet_t* convnet, ccv_array_t* categorizeds, ccv_array_t* tests, ccv_convnet_train_param_t params)
{
	assert(categorizeds->rnum >= 128);
	int i;
	ccv_dense_matrix_t* a[128];
	for (i = 0; i < 128; i++)
	{
		ccv_categorized_t* categorized = (ccv_categorized_t*)ccv_array_get(categorizeds, i);
		ccv_dense_matrix_t* image = 0;
		ccv_read(categorized->file.filename, &image, CCV_IO_ANY_FILE | CCV_IO_RGB_COLOR);
		ccv_dense_matrix_t* b = 0;
		if (image->rows > 251 && image->cols > 251)
			ccv_resample(image, &b, 0, ccv_max(251, (int)(image->rows * 251.0 / image->cols + 0.5)), ccv_max(251, (int)(image->cols * 251.0 / image->rows + 0.5)), CCV_INTER_AREA);
		else if (image->rows < 251 || image->cols < 251)
			ccv_resample(image, &b, 0, ccv_max(251, (int)(image->rows * 251.0 / image->cols + 0.5)), ccv_max(251, (int)(image->cols * 251.0 / image->rows + 0.5)), CCV_INTER_CUBIC);
		else
			b = image;
		if (b != image)
			ccv_matrix_free(image);
		ccv_dense_matrix_t* c = 0;
		ccv_slice(b, (ccv_matrix_t**)&c, CCV_32F, 0, 0, 225, 225);
		int j, ch = CCV_GET_CHANNEL(c->type);
		for (j = 0; j < c->rows * c->cols * ch; j++)
			c->data.f32[j] = c->data.f32[j] / 255.0 * 2 - 1;
		a[i] = c;
		ccv_matrix_free(b);
	}
	cog_convnet_encode(convnet, a, 0, 128);
}
