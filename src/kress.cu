
/*
* File:   kmpso.cu
* Authors: Gianluigi Silvestri, Michele Amoretti, Stefano Cagnoni
*/


#include <stdlib.h>
#include <iostream>
#include <cmath>
#include <numeric>
#include <algorithm>
#include <fstream>
#include <random>
#include <vector>
#include <cfloat>
#include <limits>
#include <string>
#include "application.h"
#include "kmpso_kernels.h"

using  namespace  std;

#define	D_max 500  // Max number of dimensions of the search space
#define	S_max 10000 // Max swarm size
#define K_max 3000 //Max number of clusters


// Global variables
double pi; // Useful for some test functions
int D; // Search space dimension
int S; // Swarm size
int K; // Number of seeds
int N; // number of results to keep
unsigned int rseed; // random seed
double *v; // vector for distance
double *V;
double *X;
double *P;
int *seed;
double *fx;
double *fp;
int *size;
double *M;
double *sigma;
double *bp;
double *fm;
bool *best;
vector < vector<unsigned int> > group(S_max, vector<unsigned int> (D_max));
int a;
double *d_X;
double *d_V;
double *d_P;
int *d_seed;
double *d_sigma;
double *d_bp;
curandState* devStates;
int TPB, NB;
double xmin, xmax; // Intervals defining the search space
int T;
vector<float> output1(S);
double x;
double c; // acceleration
double w; // constriction factor
dci::Application* app;
int fitness;
vector <double> results;
vector < vector<unsigned int> > g;
int r1, r2;
int b;

double alea( double a, double b )
{ // random number (uniform distribution) in [a b]
  double r;
  r=(double)rand(); r=r/RAND_MAX;
  return a + r * ( b - a );
}

vector<float> perf(int S, int D)
{

  // ********************************************************************* //
  // COMPUTATION SECTION - repeat as needed                                //
  // ********************************************************************* //

  // create agent list for clusters
  vector<unsigned int> cluster1(D);
  cluster1.clear();
  output1.clear();

  // allocate memory for clusters
  vector<register_t*> clusters(S);
  // allocate memory for cluster indexes
  vector<float> output(S);

  for( int s=0; s<S; s++)
  {
    group[s].clear();
    fitness++;
    for (int d=0; d<D; d++)
    {
      if (X[s*D+d]>=0)
      {
        cluster1.push_back(d);
        group[s].push_back(d);
      }
    }
    // allocate cluster bitmasks
    clusters[s] = (register_t*)malloc(app->getAgentSizeInBytes());
    // set bitmasks from agent lists
    dci::ClusterUtils::setClusterFromPosArray(clusters[s], cluster1, app->getNumberOfAgents());
    cluster1.clear();

  }

  // perform computation
  app->computeIndex(clusters, output);

  for (int s=0;s<S; s++)
  {
    // free memory
    free(clusters[s]);
  }

  return output;
}

void k_means()
{
  int k, d, s;
  int count=0;
  double k1, kt;
  bool change;
  bool insert;
  int seed1=-1;
  for (s=0;s<S;s++) seed[s]=-1;

  for (k=0; k<K; k++) //initialize seeds
  {
    for (d=0; d<D; d++)
    {
      M[k*D+d]= alea( xmin, xmax );
    }
    best[k]=false;
  }

  do
  {

    count++;
    change =false;
    for (k=0; k<K; k++)size[k]=0;
    for(s=0; s<S; s++) // for each particle i do
    {
      k1=0;
      insert=false; //doesn't belong to a cluster
      for (k=0; k<K; k++) // find the nearest seed mk
      {
        for (d=0; d<D; d++)
        {
          v[d] = P[s*D+d]-M[k*D+d];
        }
        kt=sqrt(inner_product(v, v+D, v, 0.0L)); // calculate distance p-m
        if((insert==false ) || kt<k1 )
        // if is the first evaluation or a smaller distance found
        {
          insert=true;
          k1=kt; // set the smallest distance
          seed1=k;
        }
      }
      // assign i to the cluster ck
      if(seed[s]!=seed1) // if found a nearer seed set it
      {
        seed[s]=seed1;
        change=true; // something has changed
      }
      size[seed[s]]+=1;// increase the size of the cluster

    }
    for(k=0; k<K; k++) // for each cluster recalculate the new mean
    {
      if(size[k]>0)
      {
        for(d=0; d<D; d++)
        {
          M[k*D+d]=0; // set the position to 0 to calculate the new one
          for (s=0; s<S; s++)
          {
            if (seed[s]==k)M[k*D+d]+=P[s*D+d];// for each particle in the cluster add the PB position
          }
          M[k*D+d]=M[k*D+d]/size[k]; // final new position
        }
      }
    }
  }while(change==true && count<=3);

  for(k=0;k<K;k++)
  {
    sigma[k]=0;
    if(size)
    for(s=0; s<S; s++)
    {
      if (seed[s]==k)
      {
        for (d=0; d<D; d++)
        {
          v[d] = P[s*D+d]-M[k*D+d];
        }
        sigma[k]+=inner_product(v, v+D, v, 0.0L); // distance (p-m)^2
      }
    }
    sigma[k]=sigma[k]/(size[k]-1);
  }
  cudaMemcpy(d_sigma, sigma, K*sizeof(double), cudaMemcpyHostToDevice);
  for(s=0; s<S; s++)
  {
    if(best[seed[s]]==false||fp[s]>fm[seed[s]])
    {
      fm[seed[s]]=fp[s];
      for(d=0; d<D; d++) bp[seed[s]*D+d]=P[s*D+d];
      best[seed[s]]=true;
    }

  }
  cudaMemcpy(d_bp, bp, K*D*sizeof(double), cudaMemcpyHostToDevice);
}

void update()
{
  int s, d;
  compute<<<NB, TPB>>>(d_V,d_X,d_P,d_seed,d_bp,d_sigma,xmin,xmax,S,D,c,devStates);
  cudaMemcpy(X, d_X, S*D*sizeof(double), cudaMemcpyDeviceToHost);
  cudaMemcpy(V, d_V, S*D*sizeof(double), cudaMemcpyDeviceToHost);

  output1=perf(S,D);
  for (s=0; s<S; s++)
  {
    if(!(output1[s]<= DBL_MAX))output1[s]=0;
    fx[s]=output1[s];
    if (seed[s]!=-1)
    {
      if (fx[s]>fp[s])
      {
        for(d=0; d<D; d++) P[s*D+d]=X[s*D+d];
        fp[s]=fx[s];
        if(fp[s]>fm[seed[s]])
        {
          fm[seed[s]]=fp[s];
          for(d=0; d<D; d++) bp[seed[s]*D+d]=P[s*D+d];
        }
      }

    }
    else
    {
      if (fx[s]>fp[s])
      {
        for(d=0; d<D; d++) P[s*D+d]=X[s*D+d];
        fp[s]=fx[s];

      }
    }
    for (int u=0; u<N; u++)
    {
      if(fx[s]>results[u])
      {
        for(int q=N-1; q>u; q--)
        {
          results[q]=results[q-1];
          g[q]=g[q-1];
        }
        results[u]=fx[s];
        g[u]=group[s];
        break;
      }
      else if(fx[s]==results[u])
      {
        if (g[u]==group[s]) break;
      }
    }


  }
  cudaMemcpy(d_P, P, S*D*sizeof(double), cudaMemcpyHostToDevice);
  cudaMemcpy(d_bp, bp, K*D*sizeof(double), cudaMemcpyHostToDevice);
}

void identify_niches()
{
  int navg=0; // avarage number of particles per cluster
  int nu;
  double wf; //worst fitness
  double worst=-1; // worst particle
  bool empty;
  int k, s, d;

  for(k=0; k<K; k++)
  {
    navg+=size[k];
  }
  navg=navg/K; // calculate average number of particles per cluster
  nu=0;
  for(k=0; k<K; k++)
  {
    if (size[k]>navg)
    {
      for(int z=0; z<size[k]-navg; z++)
      {
        empty=true;
        wf=0;
        for(s=0;s<S;s++)
        {
          if(seed[s]==k)
          {
            if (fx[s]<wf || empty)
            {
              wf=fx[s];
              worst=s;
              empty=false;
            }
          }
        }
        for(s=worst;s<S;s++) // remove the nj-navg worst particles from cj
        {
          for(d=0; d<D; d++)  X[s*D+d]=X[(s+1)*D+d];

          for(d=0; d<D; d++)  P[s*D+d]=P[(s+1)*D+d];


          for(d=0; d<D; d++)  V[s*D+d]=V[(s+1)*D+d];

          fx[s]=fx[s+1];
          fp[s]=fp[s+1];
          seed[s]=seed[s+1];
          group[s]=group[s+1];
        }
      }
      nu+=size[k]-navg;
      size[k]-=size[k]-navg;
    }
  }
  for(s=S-nu;s<S;s++) // reinitialize the nu un-niched particles
  {
    b=rand()%3;
    if (b==0)
    {

      do
      {
        r1=rand()%D;
        r2=rand()%D;
      }while(r1==r2);
      for ( d = 0; d < D; d++ )
      {

        if(r1==d || r2==d)
        {
          X[s*D+d] = alea( 0, xmax );
        }
        else X[s*D+d] = alea(xmin,0);
        V[s*D+d] = (alea( xmin, xmax ) - X[s*D+d])/2; // Non uniform
      }
    }
    else if(b==1)
    {
      r1=rand()%D;
      for ( d = 0; d < D; d++ )
      {
        X[s*D+d] = alea( xmin, 0);
      }
      for(d=0; d<r1; d++)
      {
        r2=rand()%D;
        X[s*D+r2] = alea(0,xmax);
      }

      for ( d = 0; d < D; d++ )
      {
        V[s*D+d] = (alea( xmin, xmax ) - X[s*D+d])/2; // Non uniform
        P[s*D+d]=X[s*D+d];
      }
    }
    else
    {
      for ( d = 0; d < D; d++ )
      {
        X[s*D+d] = alea( xmin, xmax );
        V[s*D+d] = (alea( xmin, xmax ) - X[s*D+d])/2; // Non uniform
      }

    }

    seed[s]=-1;
  }
  cudaMemcpy(d_seed, seed, S*sizeof(int), cudaMemcpyHostToDevice);
  cudaMemcpy(d_X, X, S*D*sizeof(double), cudaMemcpyHostToDevice);
  cudaMemcpy(d_V, V, S*D*sizeof(double), cudaMemcpyHostToDevice);
  output1=perf(S,D);
  for (s=0; s<S; s++)
  {
    if(!(output1[s]<= DBL_MAX))output1[s]=0;
    if (seed[s]==-1)
    {
      fx[s]=output1[s];
      for(d=0; d<D; d++) P[s*D+d]=X[s*D+d]; // Best position = current one
      fp[s]=fx[s];
    }

    for (int u=0; u<N; u++)
    {
      if(fx[s]>results[u])
      {
        for(int q=N-1; q>u; q--)
        {
          results[q]=results[q-1];
          g[q]=g[q-1];
        }
        results[u]=fx[s];
        g[u]=group[s];
        break;
      }
      else if(fx[s]==results[u])
      {
        if (g[u]==group[s]) break;
      }
    }

  }
  cudaMemcpy(d_P, P, S*D*sizeof(double), cudaMemcpyHostToDevice);
}


/*
* Prints usage
*/
void printUsage(char* command)
{
  std::cout << "USAGE:\n" << command << " --input_file:file --output_file:file --hs_input_file:file [--verbose]\n\n";
  std::cout << "PARAMETERS:\n";
  std::cout << "--tc                    use the statistical index Tc as index\n";
  std::cout << "--zi                    use zI = 2*M*I - g/ sqrt(2*g) as index (default)\n";
  std::cout << "--dimension:number      search space dimension (default 21)\n";
  std::cout << "--swarm_size:number     swarm size (default 2000)\n";
  std::cout << "--n_seeds:number        number seeds (default 7)\n";
  std::cout << "--range:number          range (default 3)\n";
  std::cout << "--n_iterations:number   number of iterations (default 501)\n";
  std::cout << "--kmeans_interv:number  intervals for identifying niches (default 20)\n";
  std::cout << "--print_interv:number   print interval (default 100)\n";
  std::cout << "--n_results:number      number of results to keep (default 100)\n";
  std::cout << "--rseed:number          random number generator seed (default 123456)\n";
  std::cout << "--input_file:string     path to the input file\n";
  std::cout << "--output_file:string    path to the output file\n";
  std::cout << "--hs_input_file:string  path to the homogeneous system input file\n";
  std::cout << "--var_string:string     list of variable names (ordered like in the input file)\n";
  std::cout << "--comp_on:number        show each group composition in  output file (0 = no | 1 = yes | default 0)\n";
  std::cout << "\n";
}


int main(int argc, char * argv[]) {
  clock_t tStart = clock();
  int d; // Current dimension
  int s; // Rank of the current particle
  int c1; // intervals for identify niches
  int interv; // print interval
  char **tokens;
  int vstr=0;
  int i, *vars;

  pi = acos( -1 ); // for rastrigin function

  // create default configuration
  dci::RunInfo configuration = dci::RunInfo();

  // default values
  D = 21;
  S = 2000;
  K = 7;
  x = 3;
  T = 501;
  c1 = 20;
  interv = 100;
  N = 100;
  rseed = 123456;
  configuration.rand_seed = rseed;
  configuration.input_file_name = "";
  string output_file = "./output-zi-kress.txt";
  configuration.hs_input_file_name = "";
  string chosen_index = "zI";
  configuration.tc_index = false;
  configuration.zi_index = true;
  string var_string = "";
  int comp_on = 0;
  configuration.good_config = false;

  int pos;

  if (argc < 2) // bad command line parameters, print error and usage
  {
    configuration.error_message = "no arguments specified";
    cout << "Error: " << configuration.error_message << "\n\n";
    printUsage(argv[0]);
    return -1;
  }

  // cycle all command-line arguments
  for (int i = 1; i < argc; ++i)
  {
    std::string arg(argv[i]);

    if (arg == "--tc")
    {
      chosen_index = "Tc";
      configuration.tc_index = true;
      configuration.zi_index = false;
    }
    else if (arg == "--zi")
    {
      chosen_index = "zI";
      configuration.tc_index = false;
      configuration.zi_index = true;
    }
    else if (arg.length() >= 2 && (pos = arg.find_first_of(':')) != std::string::npos) // this is a --XXX:VVV parameter
    {
      std::string name = arg.substr(0, pos);
      std::string value = arg.substr(pos + 1);

      if (name == "--dimension")
      D = atoi(value.data());
      else if (name == "--swarm_size")
      S = atoi(value.data());
      else if (name == "--n_seeds")
      K = atoi(value.data());
      else if (name == "--range")
      x = atoi(value.data());
      else if (name == "--n_iterations")
      T = atoi(value.data());
      else if (name == "--kmeans_interv")
      c1 = atoi(value.data());
      else if (name == "--print_interv")
      interv = atoi(value.data());
      else if (name == "--n_results")
      N = atoi(value.data());
      else if (name == "--rseed") {
        configuration.rand_seed = atoi(value.data());
        rseed = configuration.rand_seed;
      }
      //else if (name == "--hseed")
      //hseed = atoi(value.data());
      else if (name == "--input_file")
      configuration.input_file_name = value;
      else if (name == "--output_file")
      output_file = value;
      else if (name == "--hs_input_file")
      configuration.hs_input_file_name = value;
      //else if (name == "--hs_count")
      //configuration.hs_count = std::atoi(value.data());
      //else if (name == "--hsoutputfile")
      //configuration.hs_output_file_name = value;
      else if (name == "--var_string")
      var_string = value;
      else if (name == "--comp_on")
      comp_on = atoi(value.data());
    }

  } // end for cycle

  if (configuration.input_file_name == "") {
    configuration.error_message = "no input file specified";
    cout << "Error: " << configuration.error_message << "\n\n";
    return -1;
  }

  if ((configuration.hs_input_file_name == "") && (configuration.tc_index == true)) {
    configuration.error_message = "no hs input file specified";
    cout << "Error: " << configuration.error_message << "\n\n";
    return -1;
  }

  if (var_string == "") {
    std::string temp = "";
    for (int j = 0; j < D; j++) {
      temp = "[" + std::to_string(j) + "] ";
      var_string += temp;
    }
  }

  configuration.good_config = true;

  if(strlen(var_string.data())>0)
  {
    vstr=1;
    tokens = (char**) calloc(D,sizeof(char*));
    for (i=0; i<D; i++)
    {
      tokens[i] = (char *) malloc((strlen(var_string.data())+2)*sizeof(char));
    }
  }

  vars=(int *) malloc(D*sizeof(int));
  //sptr = (char *) malloc (strlen(var_string.data())*sizeof(char));
  //strcpy(sptr, var_string.data());

  tokens[0]=strtok((char *) var_string.data()," ");
  for (i=1; i<D; i++)
  {
    tokens[i]=strtok(NULL," ");
  }

  results.resize(N);
  g.resize(N);
  X = (double*) malloc(S*D*sizeof(double));
  V = (double*) malloc(S*D*sizeof(double));
  P = (double*) malloc(S*D*sizeof(double));
  v = (double*) malloc(D*sizeof(double));
  seed = (int*) malloc(S*sizeof(int));
  fx = (double*) malloc(S*sizeof(double));
  fp = (double*) malloc(S*sizeof(double));
  size = (int*) malloc(K*sizeof(int));
  M = (double*) malloc(K*D*sizeof(double));
  bp = (double*) malloc(K*D*sizeof(double));
  sigma = (double*) malloc(K*sizeof(double));
  fm = (double*) malloc(K*sizeof(double));
  best = (bool*) malloc(K*sizeof(bool));

  cudaMalloc((void **)&d_X, sizeof(double*)*S*D);
  cudaMalloc((void **)&d_V, sizeof(double*)*S*D);
  cudaMalloc((void **)&d_P, sizeof(double*)*S*D);
  cudaMalloc((void **)&d_seed, sizeof(int*)*S);
  cudaMalloc((void **)&d_sigma, sizeof(double*)*K);
  cudaMalloc((void **)&d_bp, sizeof(double*)*K*D);
  a=1024/D;
  TPB=512;
  NB=S*D/512;
  cudaMalloc ( &devStates, S*D*sizeof( curandState ) );

  cout << "rseed: " << rseed << endl;

  // create application object
  app = new dci::Application(configuration);

  // initialize application
  app->init();

  fitness=0;
  w = 0.73;
  c = 2.05;
  // D-cube data
  xmin = -x; xmax = x;

  //-----------------------INITIALIZATION
  setup_kernel <<< NB,TPB >>> ( devStates, (unsigned long) rseed );
  srand(rseed);

  for ( s = 0; s < S; s++ ) // create S particles
  {
    b = rand()%3;

    if (b==0)
    {
      do
      {
        r1 = rand()%D;
        r2 = rand()%D;
      }while(r1==r2);
      for (d = 0; d < D; d++)
      {
        if(r1==d || r2==d)
        {
          X[s*D+d] = alea( 0, xmax );
        }
        else
        X[s*D+d] = alea(xmin,0);
        V[s*D+d] = (alea( xmin, xmax ) - X[s*D+d])/2; // Non uniform
        P[s*D+d] = X[s*D+d];
      }
    }
    else if(b==1)
    {
      r1 = rand()%D;
      for (d = 0; d < D; d++)
      {
        X[s*D+d] = alea(xmin, 0);
      }
      for(d=0; d<r1; d++)
      {
        r2 = rand()%D;
        X[s*D+r2] = alea(0,xmax);
      }

      for (d = 0; d < D; d++)
      {
        V[s*D+d] = (alea( xmin, xmax ) - X[s*D+d])/2; // Non uniform
        P[s*D+d] = X[s*D+d];
      }
    }
    else
    {
      for (d = 0; d < D; d++)
      {
        X[s*D+d] = alea( xmin, xmax );
        V[s*D+d] = (alea( xmin, xmax ) - X[s*D+d])/2; // Non uniform
        P[s*D+d] = X[s*D+d];
      }
    }
  }
  cudaMemcpy(d_X, X, S*D*sizeof(double), cudaMemcpyHostToDevice);
  cudaMemcpy(d_V, V, S*D*sizeof(double), cudaMemcpyHostToDevice);
  output1 = perf(S,D);
  for (s=0; s<S; s++)
  {
    if(!(output1[s] <= DBL_MAX))output1[s]=0;
    fx[s] = output1[s];
    fp[s] = fx[s];
    for (int u=0; u<N; u++)
    {
      if(fx[s]>results[u])
      {
        for(int q=N-1; q>u; q--)
        {
          results[q]=results[q-1];
          g[q]=g[q-1];
        }
        results[u]=fx[s];
        g[u]=group[s];
        break;
      }
      else if(fx[s]==results[u])
      {
        if (g[u]==group[s]) break;
      }
    }
  }
  cudaMemcpy(d_P, P, S*D*sizeof(double), cudaMemcpyHostToDevice);

  k_means(); //k-means algorithm
  cudaMemcpy(d_seed, seed, S*sizeof(int), cudaMemcpyHostToDevice);

  //--------------------ITERATIONS
  for (int t=1; t<T; t++)
  {
    update();
    if (t % c1 ==0)
    {
      k_means();
      identify_niches();
    }

    //PRINT ON SCREEN
    std::ofstream outfile2;

    int var_count = 0;
    if(t%interv==0 || t==T-1)
    {
      if (vstr==1)
      {
        for (i=0;i<D;i++)
        outfile2 << tokens[i] << "\t";

        if (comp_on == 0)
        outfile2 << chosen_index << "\n";
        else
        outfile2 << chosen_index << "\tComp\n";
      }

      for(int u=0; u<N;u++)
      {
        for(i=0;i<D;i++) vars[i]=-1;
        int vcount=0;
        for (d=0; d<g[u].size(); d++)
        {
          for (i=var_count; i<g[u][d]; i++)
          {
            outfile2 << "0" << "\t";
          }
          outfile2 << "1" << "\t";
          vars[vcount]=i;
          var_count = g[u][d]+1;
          vcount=vcount+1;
        }
        while (var_count < D)
        {
          outfile2 << "0" << "\t";
          var_count++;
        }

        if (comp_on == 0)
        {
          outfile2 << results[u]<< "\n";
        }
        else
        {
          outfile2 << results[u]<< "\t";
          int  nv=0;
          while (vars[nv]>=0) nv++;
          for(i=0;i<nv-1;i++) outfile2 << tokens[vars[i]] << "+";
          outfile2 << tokens[vars[nv-1]] << "\n";
        }
        var_count = 0;
      }
      cout << "fitness computed " << fitness << " times\n";
      cout << "Time taken: " << (double)(clock() - tStart)/CLOCKS_PER_SEC << "s\n";
      cout <<"------------------------\n\n";
    }

    //PRINT ON FILE

    if(t==T-1)
    {
      std::ofstream outfile;

      outfile.open(output_file, std::ios_base::trunc);

      var_count = 0;

      if(vstr)
      {
        for(i=0;i<D;i++) {
          outfile << tokens[i] << "\t";
        }

        if (comp_on == 0)
        {
          outfile << chosen_index << "\n";
        }
        else
        {
          outfile << chosen_index << "\tComp\n";
        }

      }
      for(int u=0; u<N;u++) {
        for(i=0;i<D;i++) vars[i]=-1;
        int vcount=0;
        for (d=0; d<g[u].size(); d++)
        {
          for (i=var_count; i<g[u][d]; i++)
          {
            outfile << "0" << "\t";
          }
          outfile << "1" << "\t";

          vars[vcount]=i;
          var_count = g[u][d]+1;
          vcount=vcount+1;
        }
        while (var_count < D)
        {
          outfile << "0" << "\t";
          var_count++;
        }

        if (comp_on == 0)
        {
          outfile << results[u]<< "\n";
        }
        else
        {
          outfile << results[u]<< "\t";
          int  nv=0;
          while (vars[nv]>=0) nv++;
          for(i=0;i<nv-1;i++) outfile << tokens[vars[i]] << "+";
          outfile << tokens[vars[nv-1]] << "\n";
        }
        var_count = 0;
      }
      outfile.close();
    }


    outfile2.close();

  }
  // delete app object
  cudaFree(d_X);
  cudaFree(d_V);
  cudaFree(d_P);
  cudaFree(d_bp);
  cudaFree(d_seed);
  cudaFree(d_sigma);
  delete app;

  return 0;
}
