require(pROC)
require(rpart)
require(caret)
require(glmnet)
require(MASS)
require(partykit)
library(plyr)
library(ggplot2)
library(reshape2)
library(purge)

# # Calculate the number of cores
# n_cores <- detectCores() - 1
# 
# # Initiate cluster
# cl <- makeCluster(n_cores)

library(doParallel)
library(foreach)
# cl <- makeCluster(3)
# registerDoParallel(cl)
library(doMC)
registerDoMC(cores=3)  

vanillaboost = function(df,valdata=NULL,earlystopping=100,iter=1000,v=1,groups,controls,target="binary",treeType="rpart",unbalanced=FALSE,fitTreeCoef=NULL,fitLeafCoef=NULL){
  vanillam=TrainMultiTaskClassificationGradBoost(df,valdata,earlystopping,iter,v,groups,controls,target,fitTreeCoef="nocoef",fitLeafCoef="ridge")  ## fit leaf scores with simple least squares
  #vanillam=TrainMultiTaskClassificationGradBoost(df,valdata,earlystopping,iter,v,groups,controls,target)  ## fit leaf scores with simple least squares 
  return(vanillam)
}

vanillaboost2 = function(df,valdata=NULL,earlystopping=100,iter=1000,v=1,groups,controls,target="binary",treeType="rpart",unbalanced=FALSE,fitTreeCoef=NULL,fitLeafCoef=NULL){
  vanillam=TrainMultiTaskClassificationGradBoost2(df,valdata,earlystopping,iter,v,groups,controls,target,fitTreeCoef="nocoef",fitLeafCoef="ridge",fitCoef="nocoef")  ## fit leaf scores with simple least squares
  #vanillam=TrainMultiTaskClassificationGradBoost(df,valdata,earlystopping,iter,v,groups,controls,target)  ## fit leaf scores with simple least squares 
  return(vanillam)
}



paraTuneFold = function(folds,foldname,pandofunc,trdata,iter,rate,controls,fitCoef,target="binary",fitTreeCoef,fitLeafCoef){
    fold=folds[[foldname]]
    train = trdata[fold,] ## train on this
    train = trdata[fold,] ## train on this
    valdata = trdata[-fold,] ## predict on this
    #controls = rpart.control(cp=as.numeric(cp),maxsurrogate=0)
    #cat("fitting fold with params maxdepth=",controls$maxdepth," cp=",controls$cp," iter="iter,"\n")
    mshared=pandofunc(train,iter=iter,v=rate,groups=train[,"Family"],controls=controls,target=target,valdata=valdata,earlystopping = -1,fitTreeCoef=fitTreeCoef,fitLeafCoef=fitLeafCoef)
    #cvpredictions[-fold,1:(iter-1)] = mshared$log$vpred ## all predictions for this fold
    return(mshared$log$vpred)
}

# paraTuneFold = function(folds,foldname,pandofunc,trdata,iter,rate,controls,fitCoef){
#   fold=folds[[foldname]]
#   train = trdata[fold,] ## train on this
#   train = trdata[fold,] ## train on this
#   valdata = trdata[-fold,] ## predict on this
#   #controls = rpart.control(cp=as.numeric(cp),maxsurrogate=0)
#   cat("fitting fold with params maxdepth=",controls$maxdepth," cp=",controls$cp,"\n")
#   mshared=pandofunc(train,iter=iter,v=rate,groups=train[,"Family"],controls=controls,target=target,valdata=valdata,earlystopping = -1,fitCoef=fitCoef)
#   #cvpredictions[-fold,1:(iter-1)] = mshared$log$vpred ## all predictions for this fold
#   return(mshared$log$vpred)
# }

##tune a pando function with cross validation over the traindata:
## tuning rpart maxdepth,cp and num of iterations
## first tune tree params: maxdepth and cp on a fixed, probably samll number of iterations, then tune number of iterations
## for now we tune number of iterations on a validation set
#TunePando = function(pandofunc,trdata,valdata,target="binary",maxiter=1000,cv=3,fitTreeCoef="ridge",fitLeafCoef="nocoef",maxdepths=c(2,3,4,5,6,7),cps=c(0.0001),cviter=400,cvrate=0.01,trainrate=0.01){
  TunePando = function(pandofunc,trdata,valdata,target="binary",maxiter=1000,cv=3,fitTreeCoef="ridge",fitLeafCoef="nocoef",maxdepths=c(30),cps=c(0.001),cviter=400,cvrate=0.1,trainrate=0.01, trainiter=2000){
  
  
  trdata = trdata[sample(nrow(trdata)),] ## shuffle 

  if(cv>1){
    set.seed(778)
    folds = createFolds(factor(trdata[,"Label"]),k=cv,list=TRUE)
    iter=cviter
    grid = expand.grid(cp=cps,maxdepth=maxdepths) ## --> 30 = unlimited depth in rpart, maxsurrogate=0 to reduce comp time
    grid = cbind(grid,rep(NA,nrow(grid)))
    colnames(grid)[ncol(grid)]="bestCvScore"
    grid = cbind(grid,rep(NA,nrow(grid)))
    colnames(grid)[ncol(grid)]="bestCvIt"
    cat("iter is",iter,"\n")
    
    for(i in 1:nrow(grid)){
      cvpredictions = matrix(NA,nrow(trdata),ncol=iter-1) ### CV predictions per iterations
      maxdepth=grid[i,"maxdepth"]
      cp=grid[i,"cp"]
      controls = rpart.control(maxdepth = as.numeric(maxdepth),cp=as.numeric(cp))
      retval=foreach(foldname=names(folds)) %dopar% paraTuneFold(folds,foldname,pandofunc=pandofunc,trdata,iter=iter,rate=cvrate,controls=controls,fitTreeCoef=fitTreeCoef,fitLeafCoef=fitLeafCoef,target=target)
      j=1
      for(fold in folds){
        cvpredictions[-fold,1:(iter-1)] = retval[[j]]
        j=j+1
      }
      
      aucs=apply(cvpredictions,2,function(x){as.numeric(pROC::auc(pROC::roc(as.factor(trdata[,"Label"]),as.numeric(x))))})
      bestCvIt = which(aucs==max(aucs))[1]
      cat("best CV iter was:",bestCvIt,"\n")
      cat("best AUC for params maxdepth=",maxdepth," cp=",cp,":",max(aucs),"\n")
      grid[i,"bestCvScore"]=max(aucs)
      grid[i,"bestCvIt"]=bestCvIt
    }
    bestGridIdx = which(grid[,"bestCvScore"]==max(grid[,"bestCvScore"]))[1]
    bestParams = grid[bestGridIdx,]
    
    cat("found best parameters to be:", " cp=",bestParams[,"cp"]," maxdepth=",bestParams[,"maxdepth"],"\n")
    controls = rpart.control(cp=as.numeric(bestParams[,"cp"]),maxdepth=as.numeric(bestParams[,"maxdepth"]))
    #controls = rpart.control(cp=as.numeric(bestParams[,"cp"]))
  }else{
    cat("not doiong cv, running with cp=0.01")
    controls = rpart.control() # default values
  }
  #controls=rpart.control(cp=0.00001)
  # now we can use the validation set to determine the number of iterations
  rate=trainrate
  iter=trainiter
  cat("training with rate=",rate,"\n")
  cat("fitting pando with best parmaeters to find n_estimators\n")
  mpando=pandofunc(trdata,iter=iter,v=rate,groups=trdata[,"Family"],controls=controls,target=target,valdata=valdata,earlystopping = 100,fitTreeCoef=fitTreeCoef,fitLeafCoef=fitLeafCoef)
  ## train on full data
  fulltrain=rbind(trdata,valdata)
  cat("fitting pando on full data with ",as.numeric(mpando$bestScoreRound)," iterations\n")
  cat("training full with rate=",rate,"\n")
  ret=pandofunc(fulltrain,iter=mpando$bestScoreRound,v=rate,groups=fulltrain[,"Family"],controls=controls,target=target,fitTreeCoef=fitTreeCoef,fitLeafCoef=fitLeafCoef)
  return(ret)
}
#### plot feature importances and save locally: --> currently doesn work, use plotting exapmle in spam2.r to save locally :(
plotExperimentResults = function(pandoModel,perTaskModels,outdir="", postfix="",signalVars=c()){
  if(outdir==""){
    outdir=paste0(getwd(),"/plots/")
  }
  if (!file.exists(outdir)){
    dir.create(file.path(outdir))
  }  
  
  dff = FeatureImportance.BoostingModel(pandoModel$fam1) ### for pando, we can use only one family as they share the same tree structures 
  filename=paste0(outdir,"/PandoFeatureImportance",postfix,".eps")
  PlotImp(dff,signalVars = signalVars,flip = TRUE)
  dev.copy2eps(file=filename)
  
  
  
  dff = PerTaskImportances(perTaskModels)
  filename=paste0(outdir,"/PTBFeatureImportance",postfix,".eps")
  PlotImp(dff,signalVars = signalVars,flip = TRUE)
  dev.copy2eps(file=filename)
  
  
}



#### mock for group lasso
aa=matrix(1:18,ncol=3)
aa=data.frame(aa)
aa=cbind(aa,rep(1,nrow(aa)))
aa=cbind(aa,c("fam1","fam1","fam2","fam2","fam3","fam3"))
colnames(aa)=c("f1","f2","f3","Label","Family")

##########################################
scorefunc = function(label,preds,scoreType){
  if( (all(label==1)) | (all(label==-1)) ){
    cat("ghey\n")
  }
  if(scoreType=="rmse"){
    return(sqrt(mean((label-preds)**2)))
  }
  if(scoreType=="auc"){
    
    ret=roc(as.factor(label),as.numeric(preds))$auc[1]
    return(ret)
  }
}


CreateGroupLassoDesignMatrix = function(X,interceptGrouped=FALSE,isIntercept=TRUE){
  
  families = unique(X[,"Family"])
  ntasks=length(families)
  colsPerTask = (ncol(X)-2) # removing label and family columns
  colsPerTask = colsPerTask+1 # adding intercept column per each task (two different rows of code just for readibility)
  Xgl = matrix(NA,nrow=nrow(X),ncol=(colsPerTask*ntasks)+1) # the +1 is for the label
  #cat(nrow(Xgl),"XGL",ncol(Xgl),"\n")
  i=0
  
  rowend=0
  #cat("ncol of xgl is:",ncol(Xgl),"\n")
  if(interceptGrouped){
    groups=rep(1:colsPerTask,ntasks) # which group each variable belongs to. in our case, we group the same variable across tasks  
  }else{
    groups=rep(c(1:(colsPerTask-1),0),ntasks) # which group each variable belongs to. in our case, we group the same variable across tasks  
  }
  
  Xgl=c()
  ygl=c()
  for(fam in families){
    cat("update gplasso matrix with fam is :" ,fam,"out of ",length(families)," families\n")
    taskX=as.matrix(X[X[,"Family"]==fam,-which(colnames(X) %in% c("Family","Label"))])
    taskX=cbind(taskX,matrix(1,nrow=nrow(taskX),ncol=1)) # add intercept per task
    tasky = as.matrix(X[X[,"Family"]==fam,"Label"],ncol=1)
    if(is.null(Xgl)){
      Xgl=taskX
      ygl=tasky
      next
    }
    taskXpad = matrix(0,ncol=ncol(Xgl),nrow=nrow(taskX))

    Xgl=cbind(Xgl,matrix(0,ncol=ncol(taskX),nrow=nrow(Xgl)))
    taskX = cbind(taskXpad,taskX)

    Xgl = rbind(Xgl,taskX)
    ygl = rbind(ygl,tasky) 

  }
  ret=list()
  cat(nrow(ygl),"\n")
  cat(nrow(Xgl),"\n")
  ret[["X"]]=cbind(Xgl,ygl)
  ret[["groups"]]=groups
  return(ret)
}


# binaryVariablesLambda 
CreateVibratingGroupLassoDesignMatrix = function(X,interceptGrouped=FALSE,isIntercept=TRUE,binaryVariablesLambda=1){
  
  families = unique(X[,"Family"])
  ntasks=length(families)
  colsPerTask = (ncol(X)-2) # removing label and family columns
  colsPerTask = colsPerTask+1 # adding intercept column per each task (two different rows of code just for readibility)
  Xgl = matrix(NA,nrow=nrow(X),ncol=(colsPerTask*ntasks)+1) # the +1 is for the label
  #cat(nrow(Xgl),"XGL",ncol(Xgl),"\n")
  i=0
  
  rowend=0
  #cat("ncol of xgl is:",ncol(Xgl),"\n")
  if(interceptGrouped){
    groups=rep(1:colsPerTask,ntasks) # which group each variable belongs to. in our case, we group the same variable across tasks  
  }else{
    groups=rep(c(1:(colsPerTask-1),0),ntasks) # which group each variable belongs to. in our case, we group the same variable across tasks  
  }
  
  Xgl=c()
  ygl=c()
  for(fam in families){
    cat("update gplasso matrix with fam is :" ,fam,"out of ",length(families)," families\n")
    taskX=as.matrix(X[X[,"Family"]==fam,-which(colnames(X) %in% c("Family","Label"))])
    taskX=cbind(taskX,matrix(1,nrow=nrow(taskX),ncol=1)) # add intercept per task
    tasky = as.matrix(X[X[,"Family"]==fam,"Label"],ncol=1)
    if(is.null(Xgl)){
      Xgl=taskX
      ygl=tasky
      next
    }
    taskXpad = matrix(0,ncol=ncol(Xgl),nrow=nrow(taskX))
    
    Xgl=cbind(Xgl,matrix(0,ncol=ncol(taskX),nrow=nrow(Xgl)))
    taskX = cbind(taskXpad,taskX)
    
    Xgl = rbind(Xgl,taskX)
    ygl = rbind(ygl,tasky) 
    
  }
  
  ## add a column per variable, across all tasks, to allow "binary lasso" to be on the regularization path
  binaryX = c()
  for(fam in families){
    binaryX = rbind(binaryX,as.matrix(X[X[,"Family"]==fam,-which(colnames(X) %in% c("Family","Label"))]))
  }
  ## add intercept
  binaryX = cbind(binaryX,matrix(1,nrow=nrow(binaryX),ncol=1))
  
  ## express binary regularization lambda
  binaryX = binaryVariablesLambda * binaryX
  Xgl = (1-binaryVariablesLambda)*Xgl ## balance between binary solution and group lasso solution
  Xgl = cbind(Xgl,binaryX)
  groups = c(groups,unique(groups)) ## binary variables are not penalized by group lasso
  ### in order to express 
  
  ret=list()
  cat(nrow(ygl),"\n")
  cat(nrow(Xgl),"\n")
  
  ret[["X"]]=cbind(Xgl,ygl)
  ret[["groups"]]=groups
  return(ret)
}

## preds = predictions, y = true value
negBinLogLikeLoss = function(preds=preds,y=y){
  ret = log(1+exp(-2*y*preds))
  return(ret)
}

## preds = predictions, y = true value
squareLoss = function(preds,y){
  ret = (preds-y)**2
  return(ret)
}

### return the negative gradient with respect to the loss function, 
### will be simply residuals for least squares
negative_gradient = function(y,preds,groups=NULL,target="binary",unbalanced=FALSE){
  #####
  ##
  if(target=="binary"){
    preds0 = 1-preds
    preds0[preds0<0.00001]=0.00001 ## not allow very small divisions
    preds[preds<0.00001]=0.00001 ## not allow very small divisions
    
    # if(unbalanced){
    #   
    #   Iplus = as.numeric(y==1)
    #   nplus = sum(Iplus)
    #   Iminus = as.numeric(y==-1)
    #   nminus = sum(Iminus)
    #   ret = preds*((Iplus/nplus) + (Iminus/nminus))
    # }else{
    ff = 0.5*log(preds/preds0)
    ret = (2*y)/(1+exp(2*y*ff)) ## greedy function approximation, a gradient boosting machine, page 9
  # }
    #####
    
  }else if(target=="regression"){
    ret = y-preds
  }
  return(ret)
}

negative_gradient2 = function(y,preds,groups=NULL){
  ret = (2*y)/(1+exp(2*y*preds)) ## A gradient boosting machine, page 9
  return(ret)
}

negative_gradient3 = function(y,preds,groups=NULL,target="binary",unbalanced=FALSE){
  #####
  ##
  ret=matrix(0,length(y),ncol=1)
  for(group in unique(groups)){
    y_group=y[groups==group]
    preds_group=preds[groups==group]
    if(target=="binary"){
      preds0_group = 1-preds_group 
      preds0_group[preds0_group<0.00001]=0.00001 ## not allow very small divisions
      preds_group[preds_group<0.00001]=0.00001 ## not allow very small divisions
      
      # if(unbalanced){
      #   
      #   Iplus = as.numeric(y==1)
      #   nplus = sum(Iplus)
      #   Iminus = as.numeric(y==-1)
      #   nminus = sum(Iminus)
      #   ret = preds*((Iplus/nplus) + (Iminus/nminus))
      # }else{
      ff = 0.5*log(preds_group/preds0_group)
      ret_group = (2*y_group)/(1+exp(2*y_group*ff)) ## greedy function approximation, a gradient boosting machine, page 9
      # }
      #####
      
    }else if(target=="regression"){
      ret_group = y_group-preds_group
    }
    #ret_group = ret_group**2 ## we want to the sqaure gradient per group
    ret[groups==group] = ret_group
  }
  return(ret)
}





TreeWithCoef= function(treeFit,fittedCoef,intercept,treeType="rpart") {
  ### if we make the returned object from here
  ### compatible with "predict", we can 
  ### use the predict.boost
  treeFit = purge(treeFit)
  model = structure(list(treeFit=treeFit,fittedCoef=fittedCoef,intercept=intercept,treeType=treeType),class="treeWithCoef")
  return(model)
  
}

predict.treeWithCoef = function(modelObject,newdata){
  fit=modelObject$treeFit
  treeType=modelObject$treeType
  if(treeType=="rpart"){
    preds = predict(fit,newdata)    
  }else{
    preds = predict(fit,data.frame(x=newdata))  
  }
  
  
  #### TODO: change classification instance of the code to work with an underlying regression tree
  # if(fit$method=="class"){  # i think that ANYWAY we never use classification trees, behind the scenes we only do regression trees?
  #   preds=data.frame(preds[,1]) #  this takes the probability to be in class 1  
  # }
  ret=(preds*modelObject$fittedCoef)+(modelObject$intercept)

  return(ret)
}
  
### given a tree fit, return a function which given data, predicts the
### tree prediction and multiplies by the appropriate coefs according
### to which leaf the prediction falls in
TreeWithLeafCoefs= function(treeFit,leafToCoef) {
  ### if we make the returned object from here
  ### compatible with "predict", we can 
  ### use the predict.boost
  treeFit=purge(treeFit)
  model = structure(list(treeFit=treeFit,leafToCoef=leafToCoef),class="treeWithLeafCoefsModel")
  return(model)
  
}


predict.treeWithLeafCoefsModel = function(modelObject,newdata){
  
  X=newdata
  
  fit = modelObject$treeFit
  leafToCoef = modelObject$leafToCoef
  ## using the partykit package, we can get nodes for exsiting rpart object,
  ## i chekced and it corresponds exactly with rpart
  predNodes=rpart:::pred.rpart(fit, rpart:::rpart.matrix(X))
  preds = predict(fit,newdata=X) ##prediction for all X
  if(fit$method=="class"){
    preds=data.frame(preds[,1]) #  this takes the probability to be in class 1  
  }
  
  
  nodeValues = unique(predNodes)
  predCoefs = rep(0,length(preds))
  for(node in nodeValues){
    ##prepare for each prediction, by which coefficient it should be multiplied
    ##if it belongs to $node, multiply it by the matching coefficient
    if(is.na(leafToCoef[[node]])){
      #leafToCoef[[node]]=1.0
      stop(TRUE)
    }
    predCoefs[predNodes==node]=leafToCoef[[node]]
    
  }
  #cat(predCoefs,"\n")
  return(predCoefs)
  
}


BoostingModel= function(model,rate) {
  ## generic additive model. model should be a list of models, their prediction on data will be the added 
  ## value
  model = structure(list(modelList=model,rate=rate),class="BoostingModel")
  return(model)
  
}

predict.BoostingModel = function(m,X,calibrate=TRUE,bestIt=NULL,rate=NULL){
  if(is.null(rate)){
    rate=m$rate  
  }

  ## first, for each of the fitted sub models, create a prediction at X
  pred=rep(m$modelList[[1]],nrow(X)) ## fill with the initial guess
  if(is.null(bestIt)){
    bestIt=length(m$modelList)
  }
  if(bestIt>1){
    for(i in 2:bestIt){
      if(i > length( m$modelList)){
        cat("model is length ", length(m$modelList)," i is ", i,"\n")
      }
      mm = m$modelList[[i]]  # extract i-th tree
      newpred=predict(modelObject=mm,newdata=X)
      pred = pred+(rate*newpred)
      #pred = pred+newpred
      pred = as.matrix(pred,ncol=1)
      if(nrow(pred) != nrow(X)){
        cat("predict in submodel yielded different number of rows\n")
      }
    }
  }
  if(calibrate){
    pred = 1/(1+exp(-2*pred)) ## convert to logistic score  
  }
  return(pred)
  
}









LogLoss<-function(actual, predicted)
{
  actual[actual==-1]=0 ## fix if we got {-1,1} instead of {0,1}, otherwise will do nothing
  result<- -1/length(actual)*(sum((actual*log(predicted)+(1-actual)*log(1-predicted))))
  return(result)
}




BoostingModelFeatureImportance = function(model){
  n = length(model)
  importances=list()
  sum=0
  for(i in 2:n){
    imp = model$modelList[[i]]$treeFit$variable.importance
    
    for(v in names(imp)){
      if(is.null(importances$v)){
        importances[[v]]=0
      }
      importances[[v]]= importances[[v]]+as.numeric(imp[v])
    }
  }
  return(importances)
}




featureImp.BoostingModel = function(m){
  tt1=BoostingModelFeatureImportance(m)
  return(tt1)
}

FeatureImportance.BoostingModel = function(m,title=""){
  imp1=featureImp.BoostingModel(m) # dispatch feature importance
  dff <- melt(ldply(imp1, data.frame))
  dff=dff[,-2]
  colnames(dff)=c("varname","value")
  dff=dff[order(-dff[,"value"]),]
  dffnorm=dff
  dffnorm[,"value"]=dffnorm[,"value"]/sum(dffnorm[,"value"])
  colnames(dffnorm)=c("varname","value")
  #dffnorm <- base::transform(dffnorm, varname = reorder(varname, -value))
  dffnorm=dffnorm[order(-dffnorm[,"value"]),]
  return(dffnorm)
}

 


PerTaskImportances=function(perTaskModels){
  allimp=NULL
  for(fam in names(perTaskModels)[grepl("fam",names(perTaskModels))]){
    dff=FeatureImportance.BoostingModel(perTaskModels[[fam]][[fam]])
    if(is.null(allimp)){
      allimp = dff
      next
    }
    modelFeatures=levels(dff[,"varname"])
    for(var in modelFeatures){
      if(var %in% allimp[,"varname"]){
        allimp[allimp[,"varname"]==var,"value"] = as.numeric(allimp[allimp[,"varname"]==var,"value"])+dff[dff[,"varname"]==var,"value"]
      }else{
        newvar=matrix(c(var,dff[dff[,"varname"]==var,"value"]),nrow=1,ncol=2)
        colnames(newvar)=c("varname","value")
        allimp=rbind(allimp,newvar)
      }
    }
  }  
  dffnorm=allimp
  dffnorm[,"value"]=as.numeric(dffnorm[,"value"])/sum(as.numeric(dffnorm[,"value"]))
  dffnorm <- dffnorm[order(-dffnorm[,"value"]),]
  return(dffnorm)
}




## df = feature importance dataframem generated by FeatureImportance.BoostingModel
## for pando we used FeatureImportance.BoostingModel(mshared$fam1) to generate df (as it doesn't matter which family (they all use the same trees))
## for per task boosting models we use PerTaskImportances(perTaskModels) to get a df which reflects joint feature importance across tasks
PlotImp = function(df,signalVars=c(), title="",  flip=FALSE, nfirstvar=30){
  df <- base::transform(df, varname = reorder(varname, if(flip) value else -value))
  if(length(signalVars)==0){
    signalVarNames = df[,"varname"]
  }else{
    signalVarNames = c(paste0("X",signalVars))  
  }
  df[,"Legend"]="noise"
  df[df[,"varname"] %in% signalVarNames,"Legend"]="signal"
  group.colors <- c(noise = "black", signal = "grey") 
  p3 = ggplot(head(df,n=nfirstvar), aes(varname, weight = value,fill=Legend)) + geom_bar()
  p3 = p3+scale_fill_manual(values=group.colors)
  p3 = p3 + labs(title = title)
  p3 = p3+ylab("normalized split gain")
  if(flip){
    p3=p3+coord_flip()
  }
  p3  
}