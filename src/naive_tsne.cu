/**
 * @brief Implementation of naive T-SNE
 * 
 * @file naive_tsne.cu
 * @author David Chan
 * @date 2018-04-04
 */

 #include "naive_tsne.h"

struct func_inc_inv {
    __host__ __device__ float operator()(const float &x) const { return 1 / (x + 1); }
};

struct func_kl {
    __host__ __device__ float operator()(const float &x, const float &y) const { 
        return x == 0.0f ? 0.0f : x * (log(x) - log(y));
    }
};

struct func_exp {
    __host__ __device__ float operator()(const float &x) const { return exp(x); }
};

struct func_entropy_kernel {
    __host__ __device__ float operator()(const float &x) const { float val = x*log2(x); return val != val ? 0 : val; }
};

struct func_pow2 {
    __host__ __device__ float operator()(const float &x) const { return pow(x,2); }
};

thrust::device_vector<float> compute_pij(cublasHandle_t &handle, 
                                         thrust::device_vector<float> &points, 
                                         thrust::device_vector<float> &sigma, 
                                         const unsigned int N, 
                                         const unsigned int NDIMS) 
{
    thrust::device_vector<float> pij_vals(N * N);
    squared_pairwise_dist(handle, pij_vals, points, N, NDIMS);

    thrust::device_vector<float> sigma_squared(sigma.size());
    square(sigma, sigma_squared);
    
    broadcast_matrix_vector(pij_vals, sigma_squared, N, N, thrust::divides<float>(), 1, -2.0f);
    thrust::transform(pij_vals.begin(), pij_vals.end(), pij_vals.begin(), func_exp());
    zero_diagonal(pij_vals, N);
    // reduce_sum over rows
    auto sums = reduce_sum(handle, pij_vals, N, N, 1);
    // divide column by resulting vector
    broadcast_matrix_vector(pij_vals, sums, N, N, thrust::divides<float>(), 0, 1.0f);
    float alpha = 0.5f/N;
    float beta = 0.5f/N;
    thrust::device_vector<float> pij_output(N*N);
    cublasSafeCall(cublasSgeam(handle, CUBLAS_OP_N, CUBLAS_OP_T, N, N, &alpha, thrust::raw_pointer_cast(pij_vals.data()), N, 
                               &beta, thrust::raw_pointer_cast(pij_vals.data()), N, thrust::raw_pointer_cast(pij_output.data()), N));

    // Compute the perplexity of the distribution
    thrust::transform(pij_output.begin(), pij_output.end(), pij_vals.begin(), func_entropy_kernel());

    auto perplexity = reduce_alpha(handle, pij_vals, N, N, -1.0f, 1); // Reduce the sum over the rows

    thrust::transform(perplexity.begin(), perplexity.end(), perplexity.begin(), func_pow2());

    // Print the perplexity
    for (int i = 0; i < N; i++)
        std::cout << perplexity[i] << " ";
    std::cout << std::endl;

    return pij_output;
}

/**
  * Gradient formula from http://www.jmlr.org/papers/volume9/vandermaaten08a/vandermaaten08a.pdf
  * 
  * Given by ->
  *     forces_i = 4 * \sum_j (pij - qij)(yi - yj)(1 + ||y_i - y_j||^2)^-1
  * 
  * Notation below - in comments, actual variables in the code are referred to by <varname>_ to differentiate from the mathematical quantities
  *                     It's hard to name variables correctly because we don't want to keep allocating more memory. There's probably a better solution than this though.
  */
float compute_gradients(cublasHandle_t &handle, 
                        thrust::device_vector<float> &forces,
                        thrust::device_vector<float> &dist, 
                        thrust::device_vector<float> &ys, 
                        thrust::device_vector<float> &pij, 
                        thrust::device_vector<float> &qij, 
                        const unsigned int N,
                        float eta) 
{
    // dist_ = ||y_i - y_j||^2
    squared_pairwise_dist(handle, dist, ys, N, PROJDIM);
    // dist_ = (1 + ||y_i - y_j||^2)^-1
    thrust::transform(dist.begin(), dist.end(), dist.begin(), func_inc_inv());
    zero_diagonal(dist, N);

    // qij_ = (1 + ||y_i - y_j||^2)^-1 / \Sum_{k != i} (1 + ||y_i - y_k||^2)^-1
    thrust::copy(dist.begin(), dist.end(), qij.begin());
    auto sums = reduce_sum(handle, qij, N, N, 1);
    broadcast_matrix_vector(qij, sums, N, N, thrust::divides<float>(), 0, 1.0f);
    // Compute loss = \sum_ij pij * log(pij / qij)
    thrust::device_vector<float> loss_(N * N);
    thrust::transform(pij.begin(), pij.end(), qij.begin(), loss_.begin(), func_kl());
    zero_diagonal(loss_, N);

    // printarray(loss_, N, N);
    float loss = thrust::reduce(loss_.begin(), loss_.end(), 0.0f, thrust::plus<float>());

    // qij_ = pij - qij
    thrust::transform(pij.begin(), pij.end(), qij.begin(), qij.begin(), thrust::minus<float>());
    // qij_ = (pij - qij)(1 + ||y_i - y_j||^2)^-1
    thrust::transform(qij.begin(), qij.end(), dist.begin(), qij.begin(), thrust::multiplies<float>());

    // forces_ = \sum_j (pij - qij)(1 + ||y_i - y_j||^2)^-1
    float alpha = 1.0f;
    float beta = 0.0f;
    thrust::device_vector<float> ones(PROJDIM * N, 1.0f);
    cublasSafeCall(cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, N, PROJDIM, N, &alpha, 
                                thrust::raw_pointer_cast(qij.data()), N, thrust::raw_pointer_cast(ones.data()), N, &beta, 
                                thrust::raw_pointer_cast(forces.data()), N));

    // forces_ = y_i * \sum_j (pij - qij)(1 + ||y_i - y_j||^2)^-1
    thrust::transform(forces.begin(), forces.end(), ys.begin(), forces.begin(), thrust::multiplies<float>());
    alpha = -4.0f * eta;
    beta = 4.0f * eta;
    // forces_ = 4 * y_i * \sum_j (pij - qij)(1 + ||y_i - y_j||^2)^-1 - 4 * \sum_j y_j(pij - qij)(1 + ||y_i - y_j||^2)^-1
    cublasSafeCall(cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, N, PROJDIM, N, &alpha, 
                                thrust::raw_pointer_cast(qij.data()), N, thrust::raw_pointer_cast(ys.data()), N, &beta, 
                                thrust::raw_pointer_cast(forces.data()), N));

    return loss;
}

thrust::device_vector<float> naive_tsne(cublasHandle_t &handle, 
                                        thrust::device_vector<float> &points, 
                                        const unsigned int N, 
                                        const unsigned int NDIMS)
{
    max_norm(points);
    thrust::device_vector<float> sigmas(N, 0.5f);
    auto pij = compute_pij(handle, points, sigmas, N, NDIMS);
    thrust::device_vector<float> forces(N * PROJDIM);

    thrust::device_vector<float> ys = random_vector(N * PROJDIM);
    
    // Momentum variables
    thrust::device_vector<float> yt_1(N * PROJDIM);
    thrust::device_vector<float> momentum(N * PROJDIM);
    float momentum_weight = 0.9f;


    //printarray(ys, N, 2);
    thrust::device_vector<float> qij(N * N);
    thrust::device_vector<float> dist(N * N);
    float eta = 0.10f;
    float loss = 0.0f;//, prevloss = std::numeric_limits<float>::infinity();

    // Create a dump file for the points
    std::ofstream dump_file;
    dump_file.open ("dump.txt");
    float host_ys[N * PROJDIM];
    dump_file << N << " " << PROJDIM << std::endl;

    for (int i = 0; i < 1000; i++) {
        loss = compute_gradients(handle, forces, dist, ys, pij, qij, N, eta);
        

        // Compute the momentum
        thrust::transform(ys.begin(), ys.end(), yt_1.begin(), momentum.begin(), thrust::minus<float>());
        thrust::transform(momentum.begin(), momentum.end(), thrust::make_constant_iterator(momentum_weight), momentum.begin(), thrust::multiplies<float>() );
        thrust::copy(ys.begin(), ys.end(), yt_1.begin());

        // Apply the forces
        thrust::transform(ys.begin(), ys.end(), forces.begin(), ys.begin(), thrust::plus<float>());
        thrust::transform(ys.begin(), ys.end(), momentum.begin(), ys.begin(), thrust::plus<float>());
        
        // if (loss > prevloss)
            // eta /= 2.;
        if (i % 10 == 0)
            std::cout << "Iteration: " << i << ", Loss: " << loss << ", ForceMag: " << norm(forces) << std::endl;
        // prevloss = loss;

        // Dump the points
        thrust::copy(ys.begin(), ys.end(), host_ys);
        for (int i = 0; i < N; i++) {
            for (int j = 0; j < PROJDIM; j++) {
                dump_file << host_ys[i + j*N] << " ";
            }
            dump_file << std::endl;
        }
    }
    dump_file.close();
    return ys;
}

