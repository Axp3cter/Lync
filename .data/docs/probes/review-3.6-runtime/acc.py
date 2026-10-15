import random
def sim(fps, noise, secs=60, seed=1, spikes=0.0):
    r=random.Random(seed); a=1/60; t=0; n=0; maxwin=0; times=[]
    while t<secs:
        d=(1/fps)*(1+r.uniform(-noise,noise))
        if spikes and r.random()<spikes: d*=2
        t+=d; a=min(a+d,2/60)
        if a>=1/60: a-=1/60; n+=1; times.append(t)
    # max flushes in any 1 s window
    j=0; best=0
    for i in range(len(times)):
        while times[i]-times[j]>1.0: j+=1
        best=max(best,i-j+1)
    return n/t, best
for fps in (30,59,60,61,120,144,240):
    for noise in (0.0,0.01,0.05):
        print(fps,noise,["%.2f Hz, max %d per 1 s"%sim(fps,noise,seed=s) for s in (1,2)])
