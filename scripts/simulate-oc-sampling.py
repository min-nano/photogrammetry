#!/usr/bin/env python3
"""Object Capture の結果だけで全成分を得るサンプリング方針の数値実験.

なぜこれが要るか: macOS も GPU も無いリモートセッションでは実際の Object Capture を
回せない。しかし「どう抽出すれば何回で収束するか」は**神託の仕様さえ決まれば
純粋な確率の問題**なので、神託を模した模型を回せばこの場で答えが出る。
docs/design-oc-only-sampling.md の数表はすべてこのスクリプトが生成したもの。

模型（docs/design-oc-only-sampling.md §2 と対）:

  * 現場は C 個の成分（連結しない塊）に分かれる。成分 c は長さ N_c の鎖で、
    潜在位置 i の写真は |i-j| <= k の写真とだけ重なる（k = 重なり半径）。
  * 各写真は確率 p で「有効」。無効な写真は姿勢が付かず、鎖も繋がない。
  * 神託 OC(S): S の有効写真だけで鎖を組み、隣接（位置差 <= k）で連結成分に割る。
    最大の連結断片 L について
      - |L| < minPhotos なら失敗
      - absolute 判定: |L| >= q * |S| なら L を返す。さもなくば失敗（= error 6）
      - relative 判定: |L| >= 2 * |2 番目| なら L を返す（q 仮説の対抗馬）
    返すのは常に **1 つだけ**（OC は複数モデルを同時に出せない）。

使い方:

    # 1 回の無作為抽出が通る確率（冷たい起動）
    python3 scripts/simulate-oc-sampling.py cold --N 1424 --M 1000 --k 4 --trials 400

    # 方針全体を回して所要走行回数を測る
    python3 scripts/simulate-oc-sampling.py policy --N 1424 --M 1000 --k 4 \\
        --components 600,400,300,124 --trials 40

    # N/M を掃引して「使える境界」を出す
    python3 scripts/simulate-oc-sampling.py sweep --M 1000 --k 4 --trials 200
"""

import argparse
import math
import random
import sys


# ---------------------------------------------------------------- 現場の生成

def build_site(component_sizes, p, rng):
	"""成分ごとの鎖として現場を作り、(全写真, 有効判定) を返す."""
	photos = []
	for c, size in enumerate(component_sizes):
		for i in range(size):
			photos.append((c, i))
	valid = {ph: (rng.random() < p) for ph in photos}
	return photos, valid


def parse_components(spec, N):
	"""'600,400,300' 形式、または個数だけの指定を成分サイズの列にする."""
	if spec is None:
		return [N]
	if "," in spec:
		sizes = [int(x) for x in spec.split(",") if x.strip()]
		if sum(sizes) != N:
			raise SystemExit(f"成分サイズの合計 {sum(sizes)} が N={N} と一致しません")
		return sizes
	count = int(spec)
	base = N // count
	sizes = [base] * count
	sizes[0] += N - base * count
	return sizes


# ---------------------------------------------------------------- 神託

def oracle(S, valid, k, q, min_photos, mode):
	"""OC(S) の模型。姿勢の付いた集合（1 成分の 1 断片）または None を返す."""
	by_component = {}
	for (c, i) in S:
		if valid[(c, i)]:
			by_component.setdefault(c, []).append(i)

	fragments = []
	for c, idxs in by_component.items():
		idxs.sort()
		current = [idxs[0]]
		for a, b in zip(idxs, idxs[1:]):
			if b - a <= k:
				current.append(b)
			else:
				fragments.append((c, current))
				current = [b]
		fragments.append((c, current))

	if not fragments:
		return None
	fragments.sort(key=lambda t: -len(t[1]))
	c, best = fragments[0]
	if len(best) < min_photos:
		return None

	if mode == "absolute":
		ok = len(best) >= q * len(S)
	else:
		second = len(fragments[1][1]) if len(fragments) > 1 else 0
		ok = len(best) >= 2 * second
	return set((c, i) for i in best) if ok else None


# ---------------------------------------------------------------- アンカー

def compress_anchor(posed, k, q, m, rng):
	"""姿勢の付いた集合からアンカーを作る.

	なぜ貪欲間引きなのか: 姿勢が手に入った時点で写真の並び（3 次元位置）が分かる
	ので、アンカーの間引きは**無作為ではなく決定的**にできる。「最後に残した写真から
	k 以内でいちばん遠いものを残す」を繰り返せば連結を保ったまま最大に圧縮できる。
	これが #17 §15.3 の「f* が圧縮率の上限」を改善する点（無作為間引きなら f*、
	決定的間引きなら約 1/k まで縮む）。

	ただしアンカーは入力の q 以上を占めないと走行の成功を保証できないので、
	縮めすぎた分は間引いた写真を戻して埋める。
	"""
	by_component = {}
	for (c, i) in posed:
		by_component.setdefault(c, []).append(i)

	kept, skipped = [], []
	for c, idxs in by_component.items():
		idxs.sort()
		kept.append((c, idxs[0]))
		last = idxs[0]
		i = 1
		while i < len(idxs):
			j = i
			while j + 1 < len(idxs) and idxs[j + 1] <= last + k:
				j += 1
			kept.append((c, idxs[j]))
			skipped.extend((c, x) for x in idxs[i:j])
			last = idxs[j]
			i = j + 1

	need = min(len(posed), int(math.ceil(q * m)) + 1)
	if len(kept) < need and skipped:
		kept.extend(rng.sample(skipped, min(need - len(kept), len(skipped))))
	return kept


# ---------------------------------------------------------------- 冷たい起動

def cold_start_probability(N, M, k, q, p, component_sizes, min_photos, mode, trials, rng):
	"""1 回の一様無作為抽出が通る確率と、通ったときの姿勢数を測る."""
	successes, posed_total = 0, 0
	for _ in range(trials):
		photos, valid = build_site(component_sizes, p, rng)
		m = min(M, len(photos))
		S = rng.sample(photos, m)
		res = oracle(S, valid, k, q, min_photos, mode)
		if res:
			successes += 1
			posed_total += len(res)
	return successes / trials, (posed_total / successes if successes else 0.0)


# ---------------------------------------------------------------- 方針全体

def weighted_sample(items, weights, take, rng):
	"""重み付き非復元抽出（指数レースによる。take <= len(items)）."""
	if take >= len(items):
		return list(items)
	keyed = sorted(zip((rng.expovariate(1.0) / max(w, 1e-9) for w in weights), items),
	               key=lambda t: t[0])
	return [it for _, it in keyed[:take]]


def run_policy(component_sizes, p, M, k, q, min_photos, mode, rng,
               max_runs=80, retry_budget=3, stall_limit=2, compress=True,
               decay=1.0):
	"""発見 → 完成 → 剥がし を最後まで回し、走行回数と被覆率を返す."""
	photos, valid = build_site(component_sizes, p, rng)
	valid_count = sum(1 for ph in photos if valid[ph])

	pool = set(photos)
	completed = []          # 完成した成分（姿勢の付いた集合）
	active = None           # 育て中の成分
	runs = 0
	fed = 0
	failures = 0
	retries = 0
	stall = 0
	exhausted = False
	weight = {}             # 育て中の成分に対する「まだ望みがある度」（否定証拠で減衰）

	while pool and runs < max_runs:
		if active is None:
			# 発見: プールから取れるだけ取る（密度が唯一の武器なので出し惜しみしない）
			m = min(M, len(pool))
			S = rng.sample(sorted(pool), m)
			res = oracle(S, valid, k, q, min_photos, mode)
			runs += 1
			fed += m
			if res is None:
				failures += 1
				retries += 1
				# 引き直しの予算は 1 巡目にだけ厚く配る。剥がしのたびにプールは
				# 縮み密度は上がる一方なので、2 巡目以降の失敗は「運が悪い」ではなく
				# 「もう成分が残っていない」の証拠になる。
				budget = retry_budget if not completed else 1
				if retries > budget:
					# 引き直しを使い切った。残りは「これ以上モデルにならない」
					exhausted = True
					break
			else:
				retries = 0
				active = set(res)
				stall = 0
				# 新しい成分を育て始めるので否定証拠は引き継がない
				weight = {ph: 1.0 for ph in pool}
		else:
			# 完成: アンカー（q 以上）＋ 未姿勢プールからの無作為
			m = min(M, len(pool))
			anchor = (compress_anchor(active, k, q, m, rng) if compress
			          else sorted(active))
			candidates = sorted(pool - active)
			take = max(0, min(len(candidates), m - len(anchor)))
			if take and decay < 1.0:
				drawn = weighted_sample(candidates,
				                        [weight.get(c_, 1.0) for c_ in candidates],
				                        take, rng)
			else:
				drawn = rng.sample(candidates, take) if take else []
			S = list(anchor) + drawn
			res = oracle(S, valid, k, q, min_photos, mode)
			runs += 1
			fed += len(S)
			gained = 0
			if res is None:
				failures += 1
			else:
				anchor_set = set(anchor)
				if res & anchor_set:
					before = len(active)
					active |= res
					gained = len(active) - before
				# アンカーと交わらない結果 = 別成分が勝った。ここでは捨てる
				# （実運用では「別成分の種」として控えておく）
			# 否定証拠: アンカーと一緒に投げたのに姿勢が付かなかった写真は
			# 「この成分ではない」側へ少しだけ倒す。確定ではないので減衰にとどめる
			# （前線から遠い真の会員も落ちるが、その分は減衰が弱いので自己修復する）。
			if decay < 1.0:
				posed_now = res if res else set()
				for v in drawn:
					if v not in posed_now:
						weight[v] = weight.get(v, 1.0) * decay
			stall = stall + 1 if gained == 0 else 0
			if stall >= stall_limit or take == 0:
				# 剥がし: 完成したとみなしてプールから抜く
				completed.append(active)
				pool -= active
				active = None
				stall = 0

	if active is not None:
		completed.append(active)
		pool -= active

	# 仕上げ: 残り物を成分ごとに 1 回ずつ当てにいく。アンカーが q 以上を占めるので
	# この走行は必ず通る＝必ず情報が返る（失敗しうるのは発見の走行だけ）。
	if pool and completed:
		for model in list(completed):
			if not pool:
				break
			m = min(M, len(model) + len(pool))
			anchor = compress_anchor(model, k, q, m, rng)
			take = min(len(pool), m - len(anchor))
			if take <= 0:
				continue
			S = list(anchor) + rng.sample(sorted(pool), take)
			res = oracle(S, valid, k, q, min_photos, mode)
			runs += 1
			fed += len(S)
			if res and res & set(anchor):
				picked = res - set(anchor)
				if picked:
					model |= res
					pool -= picked

	posed = sum(len(m) for m in completed)
	return {
		"runs": runs,
		"fed": fed,
		"failures": failures,
		"models": len(completed),
		"posed": posed,
		"coverage": posed / valid_count if valid_count else 0.0,
		"residue": len(pool),
		"exhausted": exhausted,
		"stuck": len(completed) == 0,
	}


# ---------------------------------------------------------------- 解析式

def f_star(n, k, q):
	"""臨界密度の解析近似 f* = 1 - (q*n)^(-1/k)（docs §3.2）."""
	return 1.0 - max(q * n, 1.0) ** (-1.0 / k)


# ---------------------------------------------------------------- CLI

def cmd_cold(args, rng):
	sizes = parse_components(args.components, args.N)
	prob, posed = cold_start_probability(
		args.N, args.M, args.k, args.q, args.p, sizes,
		args.min_photos, args.oracle, args.trials, rng)
	print(f"N={args.N} M={args.M} k={args.k} q={args.q} p={args.p} "
	      f"成分={sizes} 判定={args.oracle}")
	print(f"  密度 m/N = {min(args.M, args.N) / args.N:.3f}   "
	      f"解析 f*({args.N}) = {f_star(args.N, args.k, args.q):.3f}")
	print(f"  1 回の抽出が通る確率 = {prob:.3f}   通ったときの平均姿勢数 = {posed:.0f}")


def cmd_policy(args, rng):
	sizes = parse_components(args.components, args.N)
	rows = []
	for _ in range(args.trials):
		rows.append(run_policy(sizes, args.p, args.M, args.k, args.q,
		                       args.min_photos, args.oracle, rng,
		                       max_runs=args.max_runs,
		                       compress=not args.no_anchor_compression,
		                       decay=args.decay))
	def mean(key, src): return sum(r[key] for r in src) / len(src) if src else 0.0
	stuck = [r for r in rows if r["stuck"]]
	got = [r for r in rows if not r["stuck"]]
	print(f"N={args.N} M={args.M} k={args.k} q={args.q} p={args.p} "
	      f"成分={sizes} 判定={args.oracle} 試行={args.trials}")
	print(f"  1 つもモデルが出ない率 = {len(stuck) / len(rows):.3f}")
	if not got:
		return
	print(f"  走行回数     = {mean('runs', got):.1f}  （うち失敗 {mean('failures', got):.1f}）")
	print(f"  延べ投入枚数 = {mean('fed', got):.0f}  （N = {args.N}）")
	print(f"  得たモデル数 = {mean('models', got):.2f}  （真の成分数 {len(sizes)}）")
	print(f"  有効写真の被覆率 = {mean('coverage', got):.3f}  "
	      f"（未回収 {mean('residue', got):.0f} 枚）")


def cmd_sweep(args, rng):
	print(f"# M={args.M} k={args.k} q={args.q} p={args.p} 判定={args.oracle} "
	      f"試行={args.trials}")
	print(f"{'N':>7} {'N/M':>6} {'密度':>6} {'解析f*':>7} {'成功率':>7} {'平均姿勢':>9}")
	for N in args.points:
		sizes = parse_components(args.components, N)
		prob, posed = cold_start_probability(
			N, args.M, args.k, args.q, args.p, sizes,
			args.min_photos, args.oracle, args.trials, rng)
		print(f"{N:>7} {N / args.M:>6.2f} {min(args.M, N) / N:>6.3f} "
		      f"{f_star(N, args.k, args.q):>7.3f} {prob:>7.3f} {posed:>9.0f}")


def main(argv=None):
	ap = argparse.ArgumentParser(description=__doc__,
	                             formatter_class=argparse.RawDescriptionHelpFormatter)
	sub = ap.add_subparsers(dest="cmd", required=True)

	def common(p):
		p.add_argument("--M", type=int, default=1000, help="1 回に投入できる上限枚数")
		p.add_argument("--k", type=int, default=4, help="重なり半径（前後何枚と重なるか）")
		p.add_argument("--q", type=float, default=0.5, help="モデルが出る入力比の下限")
		p.add_argument("--p", type=float, default=0.95, help="有効写真の比率")
		p.add_argument("--components", default=None,
		               help="成分サイズ '600,400' または成分数 '4'")
		p.add_argument("--min-photos", type=int, default=20, help="再構成に要る最小枚数")
		p.add_argument("--oracle", choices=["absolute", "relative"], default="absolute")
		p.add_argument("--trials", type=int, default=200)
		p.add_argument("--seed", type=int, default=1)

	c = sub.add_parser("cold", help="1 回の無作為抽出が通る確率")
	c.add_argument("--N", type=int, required=True)
	common(c)
	c.set_defaults(func=cmd_cold)

	c = sub.add_parser("policy", help="発見→完成→剥がしを最後まで回す")
	c.add_argument("--N", type=int, required=True)
	c.add_argument("--max-runs", type=int, default=80)
	c.add_argument("--decay", type=float, default=1.0,
	               help="否定証拠の減衰係数（1.0 = 使わない。0.3〜0.7 が目安）")
	c.add_argument("--no-anchor-compression", action="store_true",
	               help="アンカーを間引かず丸ごと積む（圧縮の値打ちを測るため）")
	common(c)
	c.set_defaults(func=cmd_policy)

	c = sub.add_parser("sweep", help="N を掃引して使える境界を出す")
	c.add_argument("--points", type=int, nargs="+",
	               default=[1000, 1100, 1200, 1300, 1400, 1600, 2000, 3000, 5000])
	common(c)
	c.set_defaults(func=cmd_sweep)

	args = ap.parse_args(argv)
	rng = random.Random(args.seed)
	args.func(args, rng)
	return 0


if __name__ == "__main__":
	sys.exit(main())
