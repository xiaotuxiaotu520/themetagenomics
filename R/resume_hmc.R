#' @import lme4 rstan Rcpp
#' @importFrom stats4 summary
NULL

#' Resume HMC using a previous fit
#'
#' Perform HMC using a previously compiled Stan model. This is specifcally useful in
#' cases when a previous fit failed to converged (i.e., Rhat > 1.1 for a portion
#' of parameter estimates), thus requiring more iterations.
#'
#' @param effects_object (required) Ouput of \code{\link{est.functions}}.
#' @param init_type Type of initial parameters, either the original set that was
#' passed to \code{\link{est.functions}} or the last parameter sample from the
#' reused fit. Defaults to last.
#' @param inits List of values for parameter initialization. Overrides init_type.
#' @param iters Number of iterations for for fitting. Defaults to 300 and 100 for
#' HMC and ML, respectively.
#' @param warmup For HMC, proportion of iterations devoted to warmup. Defaults to
#' iters/2.
#' @param chains For HMC, number of parallel chains. Defaults to 1.
#' @param return_summary Logical flag to return results summary. Defaults to TRUE.
#' @param verbose Logical flag to print progress information. Defaults to FALSE.
#'
#' @return An object of class effects containing
#' \describe{
#' \item{model}{List containing the parameters, fit, and summary.}
#' \item{gene_table}{Dataframe containing the formatted predicted gene information
#' from \code{\link{predict.topics}}.}
#' }
#'
#' @references
#' Stan Development Team. 2016. RStan: the R interface to Stan.
#' http://mc-stan.org
#'
#' @seealso \code{\link[rstan]{stan}} \code{\link{est.functions}}
#'
#' @examples
#' formula <- ~s(age) + drug + sex
#' refs <- c('control','female')
#'
#' dat <- prepare_data(otu_table=OTU,rows_are_taxa=FALSE,tax_table=TAX,
#'                     metadata=META,formula=formula,refs=refs,
#'                     cn_normalize=TRUE,drop=TRUE)
#' topics <- find_topics(dat,K=15)
#' functions <- predict(topics,reference_path='/references/ko_13_5_precalculated.tab.gz')
#'
#  function_effects_init <- est(functions,level=3,iters=150,
#                               prior=c('laplace','t','laplace'))
#  function_effects <- resume(function_effects_init,init_type='last',
#                             iters=300,chains=4)
#'
#' @export
resume <- function(object,...) UseMethod('resume')

#' @export
resume.effects <- function(effects_object,init_type=c('last','orig'),inits,
                           iters,warmup=iters/2,chains=1,
                           return_summary=TRUE,verbose=FALSE){

  if (attr(effects_object,'type') != 'functions')
    stop('Effects object must contain functional infrormation.')

  if (missing(inits)){
    init_type <- match.arg(init_type)
    inits <- effects_object$model$inits[[init_type]]
  }

  if (length(inits) < chains)
    inits <- lapply(seq_len(chains),function(x){
      j <- sample(length(inits),1)
      inits[[j]]
      })

  mm <- resume(effects_object$model$fit,
               stan_dat=effects_object$model$data,
               inits=inits,warmup=warmup,
               gene_table=effects_object$gene_table,pars=effects_object$model$pars,
               iters=iters,chains=chains,return_summary=return_summary,verbose=verbose)

  out <- list(model=mm,gene_table=effects_object$gene_table)
  class(out) <- 'effects'
  attr(out,'type') <- 'functions'
  attr(out,'method') <- attr(effects_object,'method')

  return(out)

}

#' @export
resume.stanfit <- function(stan_obj,stan_dat,inits,gene_table,
                           pars,iters,warmup=iters/2,chains=1,
                           return_summary=TRUE,verbose=FALSE){

  if (chains > 1){
    if (verbose) cat('Preparing parallelization.\n')
    options_old <- options()

    on.exit(options(options_old),add=TRUE)

    rstan::rstan_options(auto_write=TRUE)
    options(mc.cores=chains)
  }

  fit <- rstan::stan(fit=stan_obj,data=stan_dat,
                     init=inits,warmup=warmup,
                     pars=c('theta'),include=FALSE,
                     iter=iters,chains=chains,
                     verbose=verbose)

  out <- list()
  out[['pars']] <- pars
  out[['fit']] <- fit
  out[['data']] <- stan_dat
  out[['inits']] <- list(orig=inits,
                         last=apply(fit,2,relist,
                              skeleton=rstan:::create_skeleton(fit@model_pars,fit@par_dims)))
  out[['sampler']] <- rstan::get_sampler_params(fit)

  if (return_summary){
    if (verbose) cat('Extracting summary (this often takes some time).\n')
    out[['summary']] <- extract_stan_summary(fit,stan_dat,pars)
    rhat_pars <- pars[pars != 'yhat']
    rhat <- summary(fit,pars=rhat_pars)[['summary']][,'Rhat'] > 1.1
    rhat_count <- sum(rhat,na.rm=TRUE)
    if (rhat_count > 0){
      warning(sprintf('%s parameters with Rhat > 1.1. Consider more iterations.',rhat_count))
      out[['flagged']] <- names(which(rhat))
    }
  }

  return(out)

}