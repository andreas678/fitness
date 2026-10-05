# B8: Warn-Signale – Redundanz, HRV-Skala, Schwellen (Rechnungen auf den echten Daten)
suppressPackageStartupMessages({library(here);library(dplyr);library(readr);library(tibble)})
source(here("scripts","helpers.R")); source(here("scripts","load_recovery.R"))
d <- read_csv(here("data","garmin_daily.csv"),show_col_types=FALSE) |> apply_annotations(read_annotations())   # wie build_dashboard.R
a <- read_csv(here("data","garmin_activities.csv"),show_col_types=FALSE,col_types=cols(activity_id=col_character(),start=col_datetime(),name=col_character(),type_key=col_character(),.default=col_double()))
am <- merge_rides(a,30,3)|>mutate(group=activity_group(type_key))
zn <- read_csv(here("data","garmin_activity_zones.csv"),show_col_types=FALSE,col_types=cols(activity_id=col_character(),.default=col_double()))
p <- athlete_profile(median(d$resting_hr[d$resting_hr>=45],na.rm=T))
dl <- daily_load_recovery(d, session_load(am,p,0.4,zn))
cat("Tage:",nrow(dl),"\n\n== 1. Redundanz der vier z-Werte (Pearson, paarweise) ==\n")
Z <- dl[,c("rhr_z","sleep_z","bb_z","hrv_z")]; print(round(cor(Z,use="pairwise.complete.obs"),2))
cat("Rohwerte (bereinigt):\n"); cl <- clean_daily(dl, extra_cols="bb_high")
R <- tibble(rhr=cl$resting_hr, sleep=cl$sleep_score, bb=cl$bb_high, hrv=cl$hrv_night)
print(round(cor(R,use="pairwise.complete.obs"),2))
cat("\n== 2. HRV: Schiefe roh vs. ln ==\n")
sk <- function(x){x<-x[!is.na(x)];mean((x-mean(x))^3)/sd(x)^3}
cat("n:",sum(!is.na(R$hrv))," Schiefe roh:",round(sk(R$hrv),2)," ln:",round(sk(log(R$hrv)),2),"\n")
cat("Schiefe Ruhepuls:",round(sk(R$rhr),2)," Schlaf:",round(sk(R$sleep),2)," BB:",round(sk(R$bb),2),"\n")
cat("Anteil Tage hrv_z<=-1 roh:",round(mean(dl$hrv_z<=-1,na.rm=T),3),"\n")
zl <- (function(x,k=28,min_n=14){m<-roll_apply(x,k,mean,min_n,1);s<-roll_apply(x,k,sd,min_n,1);ifelse(!is.na(s)&s>0,(x-m)/s,NA)})(log(R$hrv))
cat("Anteil Tage z_ln<=-1:",round(mean(zl<=-1,na.rm=T),3),"; Übereinstimmung der Flags roh/ln:",
    round(mean((dl$hrv_z<=-1)==(zl<=-1),na.rm=T),3),"; Korrelation z roh/ln:",round(cor(dl$hrv_z,zl,use="pair"),3),"\n")
cat("\n== 3. Flag-Anzahl: beobachtet vs. unter Unabhängigkeit (gleiche Randhäufigkeiten) ==\n")
S <- dl[,c("sig_rhr","sig_sleep","sig_bb","sig_hrv")]; ok <- complete.cases(Z); pr <- colMeans(S[ok,]) 
cat("Auslöserate je Signal:",paste(names(pr),round(pr,3),collapse="  "),"\n")
# exakte Verteilung der Summe unabhängiger Bernoulli
dist <- Reduce(function(acc,q) c(acc*(1-q),0)+c(0,acc*q), pr, 1)
obs <- tabulate(rowSums(S[ok,])+1, 5)/sum(ok)
print(rbind(beobachtet=round(obs,3), unabhaengig=round(dist,3)))
cat("P(>=2): beobachtet",round(sum(obs[3:5]),3)," unabhängig",round(sum(dist[3:5]),3),"\n")
cat("\n== 4. Redundanz Schlaf/BB: gemeinsames Auslösen ==\n")
cat("P(bb|sleep)=",round(mean(S$sig_bb[ok&S$sig_sleep==1]),3)," P(bb|nicht sleep)=",round(mean(S$sig_bb[ok&S$sig_sleep==0]),3),"\n")
cat("Tage mit >=2 Flags, davon nur durch Schlaf+BB:",
    sum(rowSums(S[ok,])>=2 & S$sig_sleep[ok]==1 & S$sig_bb[ok]==1 & S$sig_rhr[ok]==0 & S$sig_hrv[ok]==0),"von",sum(rowSums(S[ok,])>=2),"\n")
cat("\n== 5. Externer Bezug HRV: Garmin-Status/Baseline ==\n")
print(table(garmin=d$hrv_status[match(dl$date,d$date)], eigenes_flag=dl$sig_hrv, useNA="ifany"))
inb <- d$hrv_night < d$hrv_base_low; cat("hrv_night unter Garmin-Baseline:",sum(inb,na.rm=T),"Tage; eigenes Flag davon:",sum(inb & dl$sig_hrv[match(d$date,dl$date)]==1,na.rm=T),"\n")
cat("\n== 6. Schwellen-Sensitivität: Anteil Tage mit >=2 Signalen ==\n")
for (zc in c(1,1.5,2)) for (zl_ in c(-0.75,-1,-1.5)) {
  f <- (dl$rhr_z>=zc)+(dl$sleep_z<=zl_)+(dl$bb_z<=zl_)+(dl$hrv_z<=zl_); f<-f[ok]
  cat(sprintf("RHR>=%.2f, andere<=%.2f: %.1f%% der Tage\n", zc, zl_, 100*mean(f>=2)))
}
cat("\n== 7. Baseline: Autokorrelation und Fenstereffekt ==\n")
for (nm in names(R)) { x<-R[[nm]]; ac<-acf(x,lag.max=1,na.action=na.pass,plot=FALSE)$acf[2]; cat(nm,"Lag-1-ACF:",round(ac,2),"\n") }
cat("\n== 8. Erholungs-Index (aus der Pipeline) ==\n")
i <- attr(dl, "rec_index_info"); cat("n_eff:", round(i$n_eff, 2), " Tage mit Index:", sum(!is.na(dl$rec_index)), " rec_low:", sum(dl$rec_low),
  sprintf("(%.1f %%)", 100 * mean(dl$rec_low[!is.na(dl$rec_index)])), "\n")
cat("rec_low und alt (>= 2 Signale):\n"); print(table(rec_low = dl$rec_low, alt_ge2 = dl$flags >= 2))
