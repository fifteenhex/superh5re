/*
 * Logical and shift instructions (Vol. 2 ch. 2): AND, ANDC, OR, XOR, ANDI,
 * ORI, XORI, SHLLD, SHLLD.L, SHLRD, SHLRD.L, SHARD, SHARD.L, SHLLI, SHLLI.L,
 * SHLRI, SHLRI.L, SHARI, SHARI.L.
 *
 * Points of the manual this group is built around:
 *  - the 64-bit register shifts use ZeroExtend6(Rn), the .L forms
 *    ZeroExtend5(Rn); the rest of Rn is ignored (manual pp. 264-275);
 *  - the .L forms work on the low 32 bits of Rm and sign-extend the 32-bit
 *    result, so e.g. SHLLD.L of 1 by 31 gives 0xffffffff80000000;
 *  - the immediate shifts take a 6-bit s; the .L forms use only its low
 *    5 bits ("the highest bit of the 6-bit immediate s is ignored").  The
 *    assembler refuses s > 31 for the .L mnemonics, so those encodings are
 *    emitted as raw words through fixed registers (ASM_SHIFTI_L_RAW);
 *  - ANDI/ORI take SignExtend10(s), XORI SignExtend6(s).
 *
 * The reference shifts are computed bit by bit over a table of powers of
 * two built by doubling: a plain C `a << n` would compile to the very
 * SHmedia shift under test, with the same (unmasked) amount register, and
 * could not catch an emulator that masks the amount wrongly.
 */
#include "harness.h"

#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))

/* Extension widths the manual uses here and harness.h does not provide. */
static inline s64 SignExtend6(u64 v)
{
	return (s64)(v & 0x3f) - ((v & 0x20) ? 0x40 : 0);
}
static inline s64 SignExtend10(u64 v)
{
	return (s64)(v & 0x3ff) - ((v & 0x200) ? 0x400 : 0);
}
static inline u64 ZeroExtend5(u64 v) { return v & 0x1f; }
static inline u64 ZeroExtend6(u64 v) { return v & 0x3f; }

/* ---- reference shifts, no shift instructions involved ---------------- */

static u64 pow2[64];

static void init_pow2(void)
{
	u64 p = 1;
	unsigned i;

	for (i = 0; i < 64; i++) {
		pow2[i] = p;
		p += p;
	}
}

static int bit(u64 v, unsigned k)
{
	return (v & pow2[k]) != 0;
}

/* v << n for n < 64 */
static u64 ref_shl(u64 v, unsigned n)
{
	u64 r = 0;
	unsigned k;

	for (k = 0; k + n < 64; k++)
		if (bit(v, k))
			r |= pow2[k + n];
	return r;
}

/* v >> n for n < 64, logical or arithmetic (copies of bit 63 shifted in) */
static u64 ref_shr(u64 v, unsigned n, int arith)
{
	u64 r = 0;
	unsigned k;

	for (k = 0; k < 64; k++) {
		int b = k + n < 64 ? bit(v, k + n) : (arith && bit(v, 63));

		if (b)
			r |= pow2[k];
	}
	return r;
}

/* Pseudocode of SHLLD/SHLRD/SHARD and the .L forms (pp. 264-273).  The
 * immediate forms are the same with imm in place of Rn: SHLLI uses
 * ZeroExtend6(SignExtend6(s)) == s, SHLLI.L ZeroExtend5(SignExtend6(s)) ==
 * s & 31 (pp. 266-275). */
static u64 ref_shlld(u64 a, u64 n) { return ref_shl(a, ZeroExtend6(n)); }
static u64 ref_shlrd(u64 a, u64 n) { return ref_shr(a, ZeroExtend6(n), 0); }
static u64 ref_shard(u64 a, u64 n) { return ref_shr(a, ZeroExtend6(n), 1); }
static u64 ref_shlld_l(u64 a, u64 n)
{
	return SignExtend32(ref_shl(ZeroExtend32(a), ZeroExtend5(n)));
}
static u64 ref_shlrd_l(u64 a, u64 n)
{
	return SignExtend32(ref_shr(ZeroExtend32(a), ZeroExtend5(n), 0));
}
static u64 ref_shard_l(u64 a, u64 n)
{
	return SignExtend32(ref_shr(SignExtend32(a), ZeroExtend5(n), 1));
}

/* ---- executing instructions with a run-time immediate ---------------- */

/*
 * One inline asm per literal immediate, chosen by a switch.  The lists
 * below enumerate every legal immediate of each field and call X(I, n).
 */
#define IMM10_LIST(X, I) \
	X(I,-512) X(I,-511) X(I,-510) X(I,-509) X(I,-508) X(I,-507) X(I,-506) X(I,-505) \
	X(I,-504) X(I,-503) X(I,-502) X(I,-501) X(I,-500) X(I,-499) X(I,-498) X(I,-497) \
	X(I,-496) X(I,-495) X(I,-494) X(I,-493) X(I,-492) X(I,-491) X(I,-490) X(I,-489) \
	X(I,-488) X(I,-487) X(I,-486) X(I,-485) X(I,-484) X(I,-483) X(I,-482) X(I,-481) \
	X(I,-480) X(I,-479) X(I,-478) X(I,-477) X(I,-476) X(I,-475) X(I,-474) X(I,-473) \
	X(I,-472) X(I,-471) X(I,-470) X(I,-469) X(I,-468) X(I,-467) X(I,-466) X(I,-465) \
	X(I,-464) X(I,-463) X(I,-462) X(I,-461) X(I,-460) X(I,-459) X(I,-458) X(I,-457) \
	X(I,-456) X(I,-455) X(I,-454) X(I,-453) X(I,-452) X(I,-451) X(I,-450) X(I,-449) \
	X(I,-448) X(I,-447) X(I,-446) X(I,-445) X(I,-444) X(I,-443) X(I,-442) X(I,-441) \
	X(I,-440) X(I,-439) X(I,-438) X(I,-437) X(I,-436) X(I,-435) X(I,-434) X(I,-433) \
	X(I,-432) X(I,-431) X(I,-430) X(I,-429) X(I,-428) X(I,-427) X(I,-426) X(I,-425) \
	X(I,-424) X(I,-423) X(I,-422) X(I,-421) X(I,-420) X(I,-419) X(I,-418) X(I,-417) \
	X(I,-416) X(I,-415) X(I,-414) X(I,-413) X(I,-412) X(I,-411) X(I,-410) X(I,-409) \
	X(I,-408) X(I,-407) X(I,-406) X(I,-405) X(I,-404) X(I,-403) X(I,-402) X(I,-401) \
	X(I,-400) X(I,-399) X(I,-398) X(I,-397) X(I,-396) X(I,-395) X(I,-394) X(I,-393) \
	X(I,-392) X(I,-391) X(I,-390) X(I,-389) X(I,-388) X(I,-387) X(I,-386) X(I,-385) \
	X(I,-384) X(I,-383) X(I,-382) X(I,-381) X(I,-380) X(I,-379) X(I,-378) X(I,-377) \
	X(I,-376) X(I,-375) X(I,-374) X(I,-373) X(I,-372) X(I,-371) X(I,-370) X(I,-369) \
	X(I,-368) X(I,-367) X(I,-366) X(I,-365) X(I,-364) X(I,-363) X(I,-362) X(I,-361) \
	X(I,-360) X(I,-359) X(I,-358) X(I,-357) X(I,-356) X(I,-355) X(I,-354) X(I,-353) \
	X(I,-352) X(I,-351) X(I,-350) X(I,-349) X(I,-348) X(I,-347) X(I,-346) X(I,-345) \
	X(I,-344) X(I,-343) X(I,-342) X(I,-341) X(I,-340) X(I,-339) X(I,-338) X(I,-337) \
	X(I,-336) X(I,-335) X(I,-334) X(I,-333) X(I,-332) X(I,-331) X(I,-330) X(I,-329) \
	X(I,-328) X(I,-327) X(I,-326) X(I,-325) X(I,-324) X(I,-323) X(I,-322) X(I,-321) \
	X(I,-320) X(I,-319) X(I,-318) X(I,-317) X(I,-316) X(I,-315) X(I,-314) X(I,-313) \
	X(I,-312) X(I,-311) X(I,-310) X(I,-309) X(I,-308) X(I,-307) X(I,-306) X(I,-305) \
	X(I,-304) X(I,-303) X(I,-302) X(I,-301) X(I,-300) X(I,-299) X(I,-298) X(I,-297) \
	X(I,-296) X(I,-295) X(I,-294) X(I,-293) X(I,-292) X(I,-291) X(I,-290) X(I,-289) \
	X(I,-288) X(I,-287) X(I,-286) X(I,-285) X(I,-284) X(I,-283) X(I,-282) X(I,-281) \
	X(I,-280) X(I,-279) X(I,-278) X(I,-277) X(I,-276) X(I,-275) X(I,-274) X(I,-273) \
	X(I,-272) X(I,-271) X(I,-270) X(I,-269) X(I,-268) X(I,-267) X(I,-266) X(I,-265) \
	X(I,-264) X(I,-263) X(I,-262) X(I,-261) X(I,-260) X(I,-259) X(I,-258) X(I,-257) \
	X(I,-256) X(I,-255) X(I,-254) X(I,-253) X(I,-252) X(I,-251) X(I,-250) X(I,-249) \
	X(I,-248) X(I,-247) X(I,-246) X(I,-245) X(I,-244) X(I,-243) X(I,-242) X(I,-241) \
	X(I,-240) X(I,-239) X(I,-238) X(I,-237) X(I,-236) X(I,-235) X(I,-234) X(I,-233) \
	X(I,-232) X(I,-231) X(I,-230) X(I,-229) X(I,-228) X(I,-227) X(I,-226) X(I,-225) \
	X(I,-224) X(I,-223) X(I,-222) X(I,-221) X(I,-220) X(I,-219) X(I,-218) X(I,-217) \
	X(I,-216) X(I,-215) X(I,-214) X(I,-213) X(I,-212) X(I,-211) X(I,-210) X(I,-209) \
	X(I,-208) X(I,-207) X(I,-206) X(I,-205) X(I,-204) X(I,-203) X(I,-202) X(I,-201) \
	X(I,-200) X(I,-199) X(I,-198) X(I,-197) X(I,-196) X(I,-195) X(I,-194) X(I,-193) \
	X(I,-192) X(I,-191) X(I,-190) X(I,-189) X(I,-188) X(I,-187) X(I,-186) X(I,-185) \
	X(I,-184) X(I,-183) X(I,-182) X(I,-181) X(I,-180) X(I,-179) X(I,-178) X(I,-177) \
	X(I,-176) X(I,-175) X(I,-174) X(I,-173) X(I,-172) X(I,-171) X(I,-170) X(I,-169) \
	X(I,-168) X(I,-167) X(I,-166) X(I,-165) X(I,-164) X(I,-163) X(I,-162) X(I,-161) \
	X(I,-160) X(I,-159) X(I,-158) X(I,-157) X(I,-156) X(I,-155) X(I,-154) X(I,-153) \
	X(I,-152) X(I,-151) X(I,-150) X(I,-149) X(I,-148) X(I,-147) X(I,-146) X(I,-145) \
	X(I,-144) X(I,-143) X(I,-142) X(I,-141) X(I,-140) X(I,-139) X(I,-138) X(I,-137) \
	X(I,-136) X(I,-135) X(I,-134) X(I,-133) X(I,-132) X(I,-131) X(I,-130) X(I,-129) \
	X(I,-128) X(I,-127) X(I,-126) X(I,-125) X(I,-124) X(I,-123) X(I,-122) X(I,-121) \
	X(I,-120) X(I,-119) X(I,-118) X(I,-117) X(I,-116) X(I,-115) X(I,-114) X(I,-113) \
	X(I,-112) X(I,-111) X(I,-110) X(I,-109) X(I,-108) X(I,-107) X(I,-106) X(I,-105) \
	X(I,-104) X(I,-103) X(I,-102) X(I,-101) X(I,-100) X(I,-99) X(I,-98) X(I,-97) \
	X(I,-96) X(I,-95) X(I,-94) X(I,-93) X(I,-92) X(I,-91) X(I,-90) X(I,-89) \
	X(I,-88) X(I,-87) X(I,-86) X(I,-85) X(I,-84) X(I,-83) X(I,-82) X(I,-81) \
	X(I,-80) X(I,-79) X(I,-78) X(I,-77) X(I,-76) X(I,-75) X(I,-74) X(I,-73) \
	X(I,-72) X(I,-71) X(I,-70) X(I,-69) X(I,-68) X(I,-67) X(I,-66) X(I,-65) \
	X(I,-64) X(I,-63) X(I,-62) X(I,-61) X(I,-60) X(I,-59) X(I,-58) X(I,-57) \
	X(I,-56) X(I,-55) X(I,-54) X(I,-53) X(I,-52) X(I,-51) X(I,-50) X(I,-49) \
	X(I,-48) X(I,-47) X(I,-46) X(I,-45) X(I,-44) X(I,-43) X(I,-42) X(I,-41) \
	X(I,-40) X(I,-39) X(I,-38) X(I,-37) X(I,-36) X(I,-35) X(I,-34) X(I,-33) \
	X(I,-32) X(I,-31) X(I,-30) X(I,-29) X(I,-28) X(I,-27) X(I,-26) X(I,-25) \
	X(I,-24) X(I,-23) X(I,-22) X(I,-21) X(I,-20) X(I,-19) X(I,-18) X(I,-17) \
	X(I,-16) X(I,-15) X(I,-14) X(I,-13) X(I,-12) X(I,-11) X(I,-10) X(I,-9) \
	X(I,-8) X(I,-7) X(I,-6) X(I,-5) X(I,-4) X(I,-3) X(I,-2) X(I,-1) \
	X(I,0) X(I,1) X(I,2) X(I,3) X(I,4) X(I,5) X(I,6) X(I,7) \
	X(I,8) X(I,9) X(I,10) X(I,11) X(I,12) X(I,13) X(I,14) X(I,15) \
	X(I,16) X(I,17) X(I,18) X(I,19) X(I,20) X(I,21) X(I,22) X(I,23) \
	X(I,24) X(I,25) X(I,26) X(I,27) X(I,28) X(I,29) X(I,30) X(I,31) \
	X(I,32) X(I,33) X(I,34) X(I,35) X(I,36) X(I,37) X(I,38) X(I,39) \
	X(I,40) X(I,41) X(I,42) X(I,43) X(I,44) X(I,45) X(I,46) X(I,47) \
	X(I,48) X(I,49) X(I,50) X(I,51) X(I,52) X(I,53) X(I,54) X(I,55) \
	X(I,56) X(I,57) X(I,58) X(I,59) X(I,60) X(I,61) X(I,62) X(I,63) \
	X(I,64) X(I,65) X(I,66) X(I,67) X(I,68) X(I,69) X(I,70) X(I,71) \
	X(I,72) X(I,73) X(I,74) X(I,75) X(I,76) X(I,77) X(I,78) X(I,79) \
	X(I,80) X(I,81) X(I,82) X(I,83) X(I,84) X(I,85) X(I,86) X(I,87) \
	X(I,88) X(I,89) X(I,90) X(I,91) X(I,92) X(I,93) X(I,94) X(I,95) \
	X(I,96) X(I,97) X(I,98) X(I,99) X(I,100) X(I,101) X(I,102) X(I,103) \
	X(I,104) X(I,105) X(I,106) X(I,107) X(I,108) X(I,109) X(I,110) X(I,111) \
	X(I,112) X(I,113) X(I,114) X(I,115) X(I,116) X(I,117) X(I,118) X(I,119) \
	X(I,120) X(I,121) X(I,122) X(I,123) X(I,124) X(I,125) X(I,126) X(I,127) \
	X(I,128) X(I,129) X(I,130) X(I,131) X(I,132) X(I,133) X(I,134) X(I,135) \
	X(I,136) X(I,137) X(I,138) X(I,139) X(I,140) X(I,141) X(I,142) X(I,143) \
	X(I,144) X(I,145) X(I,146) X(I,147) X(I,148) X(I,149) X(I,150) X(I,151) \
	X(I,152) X(I,153) X(I,154) X(I,155) X(I,156) X(I,157) X(I,158) X(I,159) \
	X(I,160) X(I,161) X(I,162) X(I,163) X(I,164) X(I,165) X(I,166) X(I,167) \
	X(I,168) X(I,169) X(I,170) X(I,171) X(I,172) X(I,173) X(I,174) X(I,175) \
	X(I,176) X(I,177) X(I,178) X(I,179) X(I,180) X(I,181) X(I,182) X(I,183) \
	X(I,184) X(I,185) X(I,186) X(I,187) X(I,188) X(I,189) X(I,190) X(I,191) \
	X(I,192) X(I,193) X(I,194) X(I,195) X(I,196) X(I,197) X(I,198) X(I,199) \
	X(I,200) X(I,201) X(I,202) X(I,203) X(I,204) X(I,205) X(I,206) X(I,207) \
	X(I,208) X(I,209) X(I,210) X(I,211) X(I,212) X(I,213) X(I,214) X(I,215) \
	X(I,216) X(I,217) X(I,218) X(I,219) X(I,220) X(I,221) X(I,222) X(I,223) \
	X(I,224) X(I,225) X(I,226) X(I,227) X(I,228) X(I,229) X(I,230) X(I,231) \
	X(I,232) X(I,233) X(I,234) X(I,235) X(I,236) X(I,237) X(I,238) X(I,239) \
	X(I,240) X(I,241) X(I,242) X(I,243) X(I,244) X(I,245) X(I,246) X(I,247) \
	X(I,248) X(I,249) X(I,250) X(I,251) X(I,252) X(I,253) X(I,254) X(I,255) \
	X(I,256) X(I,257) X(I,258) X(I,259) X(I,260) X(I,261) X(I,262) X(I,263) \
	X(I,264) X(I,265) X(I,266) X(I,267) X(I,268) X(I,269) X(I,270) X(I,271) \
	X(I,272) X(I,273) X(I,274) X(I,275) X(I,276) X(I,277) X(I,278) X(I,279) \
	X(I,280) X(I,281) X(I,282) X(I,283) X(I,284) X(I,285) X(I,286) X(I,287) \
	X(I,288) X(I,289) X(I,290) X(I,291) X(I,292) X(I,293) X(I,294) X(I,295) \
	X(I,296) X(I,297) X(I,298) X(I,299) X(I,300) X(I,301) X(I,302) X(I,303) \
	X(I,304) X(I,305) X(I,306) X(I,307) X(I,308) X(I,309) X(I,310) X(I,311) \
	X(I,312) X(I,313) X(I,314) X(I,315) X(I,316) X(I,317) X(I,318) X(I,319) \
	X(I,320) X(I,321) X(I,322) X(I,323) X(I,324) X(I,325) X(I,326) X(I,327) \
	X(I,328) X(I,329) X(I,330) X(I,331) X(I,332) X(I,333) X(I,334) X(I,335) \
	X(I,336) X(I,337) X(I,338) X(I,339) X(I,340) X(I,341) X(I,342) X(I,343) \
	X(I,344) X(I,345) X(I,346) X(I,347) X(I,348) X(I,349) X(I,350) X(I,351) \
	X(I,352) X(I,353) X(I,354) X(I,355) X(I,356) X(I,357) X(I,358) X(I,359) \
	X(I,360) X(I,361) X(I,362) X(I,363) X(I,364) X(I,365) X(I,366) X(I,367) \
	X(I,368) X(I,369) X(I,370) X(I,371) X(I,372) X(I,373) X(I,374) X(I,375) \
	X(I,376) X(I,377) X(I,378) X(I,379) X(I,380) X(I,381) X(I,382) X(I,383) \
	X(I,384) X(I,385) X(I,386) X(I,387) X(I,388) X(I,389) X(I,390) X(I,391) \
	X(I,392) X(I,393) X(I,394) X(I,395) X(I,396) X(I,397) X(I,398) X(I,399) \
	X(I,400) X(I,401) X(I,402) X(I,403) X(I,404) X(I,405) X(I,406) X(I,407) \
	X(I,408) X(I,409) X(I,410) X(I,411) X(I,412) X(I,413) X(I,414) X(I,415) \
	X(I,416) X(I,417) X(I,418) X(I,419) X(I,420) X(I,421) X(I,422) X(I,423) \
	X(I,424) X(I,425) X(I,426) X(I,427) X(I,428) X(I,429) X(I,430) X(I,431) \
	X(I,432) X(I,433) X(I,434) X(I,435) X(I,436) X(I,437) X(I,438) X(I,439) \
	X(I,440) X(I,441) X(I,442) X(I,443) X(I,444) X(I,445) X(I,446) X(I,447) \
	X(I,448) X(I,449) X(I,450) X(I,451) X(I,452) X(I,453) X(I,454) X(I,455) \
	X(I,456) X(I,457) X(I,458) X(I,459) X(I,460) X(I,461) X(I,462) X(I,463) \
	X(I,464) X(I,465) X(I,466) X(I,467) X(I,468) X(I,469) X(I,470) X(I,471) \
	X(I,472) X(I,473) X(I,474) X(I,475) X(I,476) X(I,477) X(I,478) X(I,479) \
	X(I,480) X(I,481) X(I,482) X(I,483) X(I,484) X(I,485) X(I,486) X(I,487) \
	X(I,488) X(I,489) X(I,490) X(I,491) X(I,492) X(I,493) X(I,494) X(I,495) \
	X(I,496) X(I,497) X(I,498) X(I,499) X(I,500) X(I,501) X(I,502) X(I,503) \
	X(I,504) X(I,505) X(I,506) X(I,507) X(I,508) X(I,509) X(I,510) X(I,511)

#define IMM6_LIST(X, I) \
	X(I,-32) X(I,-31) X(I,-30) X(I,-29) X(I,-28) X(I,-27) X(I,-26) X(I,-25) \
	X(I,-24) X(I,-23) X(I,-22) X(I,-21) X(I,-20) X(I,-19) X(I,-18) X(I,-17) \
	X(I,-16) X(I,-15) X(I,-14) X(I,-13) X(I,-12) X(I,-11) X(I,-10) X(I,-9) \
	X(I,-8) X(I,-7) X(I,-6) X(I,-5) X(I,-4) X(I,-3) X(I,-2) X(I,-1) \
	X(I,0) X(I,1) X(I,2) X(I,3) X(I,4) X(I,5) X(I,6) X(I,7) \
	X(I,8) X(I,9) X(I,10) X(I,11) X(I,12) X(I,13) X(I,14) X(I,15) \
	X(I,16) X(I,17) X(I,18) X(I,19) X(I,20) X(I,21) X(I,22) X(I,23) \
	X(I,24) X(I,25) X(I,26) X(I,27) X(I,28) X(I,29) X(I,30) X(I,31)

#define UIMM5_LIST(X, I) \
	X(I,0) X(I,1) X(I,2) X(I,3) X(I,4) X(I,5) X(I,6) X(I,7) \
	X(I,8) X(I,9) X(I,10) X(I,11) X(I,12) X(I,13) X(I,14) X(I,15) \
	X(I,16) X(I,17) X(I,18) X(I,19) X(I,20) X(I,21) X(I,22) X(I,23) \
	X(I,24) X(I,25) X(I,26) X(I,27) X(I,28) X(I,29) X(I,30) X(I,31)

#define UIMM6_HI_LIST(X, I) \
	X(I,32) X(I,33) X(I,34) X(I,35) X(I,36) X(I,37) X(I,38) X(I,39) \
	X(I,40) X(I,41) X(I,42) X(I,43) X(I,44) X(I,45) X(I,46) X(I,47) \
	X(I,48) X(I,49) X(I,50) X(I,51) X(I,52) X(I,53) X(I,54) X(I,55) \
	X(I,56) X(I,57) X(I,58) X(I,59) X(I,60) X(I,61) X(I,62) X(I,63)

/*
 * Raw encoding of the MSD6-style shift immediates (p. 266-275, appendix
 * A.9): 110001 m ext s d 0000 with m = r20, d = r21.  ext is 0 for
 * SHLLI.L, 2 for SHLRI.L and 6 for SHARI.L.  Used for s = 32..63, which the
 * assembler rejects for the .L mnemonics, and for s = 0..31 as a cross
 * check of the encoding path itself.
 */
#define ASM_SHIFTI_L_RAW(ext, imm, a) ({				\
	u64 _r, _a = (a);						\
	__asm__ volatile ("or %1, r63, r20\n\t"				\
			  ".long 0xc4000000 | (20 << 20) | (" #ext " << 16) | (" \
			  #imm " << 10) | (21 << 4)\n\t"			\
			  "or r21, r63, %0"					\
			  : "=r"(_r) : "r"(_a) : "r20", "r21");		\
	_r; })

#define CASE_RIR(insn, n) case n: return ASM_RIR(insn, a, n);
#define CASE_RAW(ext, n) case n: return ASM_SHIFTI_L_RAW(ext, n, a);

#define IMM_FN(name, list, X, arg)					\
	static u64 name(u64 a, s64 imm)					\
	{								\
		switch (imm) {						\
		list(X, arg)						\
		default:						\
			return 0xbadbadbadbadbad0ULL;	/* unreachable */	\
		}							\
	}

IMM_FN(run_andi, IMM10_LIST, CASE_RIR, "andi")
IMM_FN(run_ori, IMM10_LIST, CASE_RIR, "ori")
IMM_FN(run_xori, IMM6_LIST, CASE_RIR, "xori")

#define UIMM6_LIST(X, I) UIMM5_LIST(X, I) UIMM6_HI_LIST(X, I)
IMM_FN(run_shlli, UIMM6_LIST, CASE_RIR, "shlli")
IMM_FN(run_shlri, UIMM6_LIST, CASE_RIR, "shlri")
IMM_FN(run_shari, UIMM6_LIST, CASE_RIR, "shari")
IMM_FN(run_shlli_l, UIMM5_LIST, CASE_RIR, "shlli.l")
IMM_FN(run_shlri_l, UIMM5_LIST, CASE_RIR, "shlri.l")
IMM_FN(run_shari_l, UIMM5_LIST, CASE_RIR, "shari.l")
IMM_FN(run_shlli_l_raw, UIMM6_LIST, CASE_RAW, 0)
IMM_FN(run_shlri_l_raw, UIMM6_LIST, CASE_RAW, 2)
IMM_FN(run_shari_l_raw, UIMM6_LIST, CASE_RAW, 6)

/* ---- the checks ------------------------------------------------------ */

/* AND, ANDC, OR, XOR (pp. 49-50, 254, 302) */
static void check_logic(u64 a, u64 b)
{
	CHECK2("and", ASM_RRR("and", a, b), a & b, a, b);
	CHECK2("andc", ASM_RRR("andc", a, b), a & ~b, a, b);
	CHECK2("or", ASM_RRR("or", a, b), a | b, a, b);
	CHECK2("xor", ASM_RRR("xor", a, b), a ^ b, a, b);
}

/* ANDI, ORI (pp. 51, 255): imm is the assembly-syntax value, s its field */
static void check_logic_imm10(u64 a, s64 imm)
{
	u64 s = imm & 0x3ff;

	CHECK2("andi", run_andi(a, imm), a & (u64)SignExtend10(s), a, imm);
	CHECK2("ori", run_ori(a, imm), a | (u64)SignExtend10(s), a, imm);
}

/* XORI (p. 303) */
static void check_logic_imm6(u64 a, s64 imm)
{
	u64 s = imm & 0x3f;

	CHECK2("xori", run_xori(a, imm), a ^ (u64)SignExtend6(s), a, imm);
}

/* register-amount shifts, any 64-bit amount */
static void check_shift_reg(u64 a, u64 n)
{
	CHECK2("shlld", ASM_RRR("shlld", a, n), ref_shlld(a, n), a, n);
	CHECK2("shlrd", ASM_RRR("shlrd", a, n), ref_shlrd(a, n), a, n);
	CHECK2("shard", ASM_RRR("shard", a, n), ref_shard(a, n), a, n);
	CHECK2("shlld.l", ASM_RRR("shlld.l", a, n), ref_shlld_l(a, n), a, n);
	CHECK2("shlrd.l", ASM_RRR("shlrd.l", a, n), ref_shlrd_l(a, n), a, n);
	CHECK2("shard.l", ASM_RRR("shard.l", a, n), ref_shard_l(a, n), a, n);
}

/* immediate shifts, every legal s */
static void check_shift_imm(u64 a)
{
	s64 s;

	for (s = 0; s < 64; s++) {
		CHECK2("shlli", run_shlli(a, s), ref_shlld(a, s), a, s);
		CHECK2("shlri", run_shlri(a, s), ref_shlrd(a, s), a, s);
		CHECK2("shari", run_shari(a, s), ref_shard(a, s), a, s);
		if (s < 32) {
			CHECK2("shlli.l", run_shlli_l(a, s), ref_shlld_l(a, s), a, s);
			CHECK2("shlri.l", run_shlri_l(a, s), ref_shlrd_l(a, s), a, s);
			CHECK2("shari.l", run_shari_l(a, s), ref_shard_l(a, s), a, s);
		}
		/* raw encodings; for s >= 32 bit 5 of s must be ignored */
		CHECK2("shlli.l (raw)", run_shlli_l_raw(a, s), ref_shlld_l(a, s), a, s);
		CHECK2("shlri.l (raw)", run_shlri_l_raw(a, s), ref_shlrd_l(a, s), a, s);
		CHECK2("shari.l (raw)", run_shari_l_raw(a, s), ref_shard_l(a, s), a, s);
	}
}

/* Shift amounts beyond 63: only the low 6 (64-bit) or 5 (.L) bits count. */
static const u64 big_amounts[] = {
	64, 65, 95, 96, 127, 128, 0xff, 0x100, 0x7fff, 0x8000, 0xffff,
	0x10000, 0x7fffffff, 0x80000000, 0xffffffff, 0x100000000ULL,
	0x7fffffffffffffffULL, 0x8000000000000000ULL, 0xffffffffffffffffULL,
	0xffffffffffffffc0ULL,	/* low 6 bits 0 */
	0xffffffffffffffe0ULL,	/* amount 32 for 64-bit, 0 for .L */
	0xffffffffffffffdfULL,	/* amount 31 for both */
	0x0123456789abcdefULL, 0xfedcba9876543210ULL,
};

ISA_GROUP(logic)
{
	u64 a, b, n;
	s64 imm;
	unsigned i;

	init_pow2();

	/* AND, ANDC, OR, XOR */
	ISA_FOREACH_OPERAND(a) ISA_FOREACH_OPERAND(b)
		check_logic(a, b);
	for (i = 0; i < 256; i++) {
		a = isa_rand();
		b = isa_rand();
		check_logic(a, b);
	}

	/* ANDI, ORI: the whole signed 10-bit range */
	for (imm = -512; imm <= 511; imm++) {
		ISA_FOREACH_OPERAND(a)
			check_logic_imm10(a, imm);
		check_logic_imm10(isa_rand(), imm);
		check_logic_imm10(isa_rand(), imm);
	}

	/* XORI: the whole signed 6-bit range */
	for (imm = -32; imm <= 31; imm++) {
		ISA_FOREACH_OPERAND(a)
			check_logic_imm6(a, imm);
		for (i = 0; i < 8; i++)
			check_logic_imm6(isa_rand(), imm);
	}

	/* register-amount shifts: amounts 0..63, above 63, and random */
	ISA_FOREACH_OPERAND(a) {
		for (n = 0; n < 64; n++)
			check_shift_reg(a, n);
		for (i = 0; i < ARRAY_SIZE(big_amounts); i++)
			check_shift_reg(a, big_amounts[i]);
	}
	for (i = 0; i < 256; i++) {
		a = isa_rand();
		n = isa_rand();
		check_shift_reg(a, n);		/* almost always > 63 */
		check_shift_reg(a, n & 0x7f);	/* 0..127 */
	}

	/* immediate shifts: every legal immediate */
	ISA_FOREACH_OPERAND(a)
		check_shift_imm(a);
	for (i = 0; i < 32; i++)
		check_shift_imm(isa_rand());
}
