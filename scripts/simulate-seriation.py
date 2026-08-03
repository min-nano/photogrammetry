#!/usr/bin/env python3
#
#  simulate-seriation.py
#
#  **窓の作り方を、真の答えが分かる合成グラフで比べる**（docs/design-loose-clustering.md §3.9）。
#
#  なぜ要るか: 実写真 1424 枚でスペクトル並べ替え（フィードラーベクトル）を試したら
#  失敗した（隣接距離 0.388 に対し撮影順は 0.242・無関係は 0.450）。理論
#  （Atkins, Boman & Hendrickson 1998）が悪いのか、実装が悪いのか、データが悪いのかを
#  切り分けるには、**真の順序が分かっているグラフ**で同じ計算を走らせるしかない。
#
#  ここが Python なのは、この検証に macOS も Vision も要らないから（純粋にグラフの
#  話なので、リモートの Linux セッションでそのまま回せる）。**結論が出たら、同じ
#  ケースを swift test へ移す** — 仕分けの中核をテストできるようにするのが §3.9 の
#  眼目なので、この本は「Swift へ移す前の下書き」でもある。
#
#  使い方: python3 scripts/simulate-seriation.py
#
import random
from collections import deque

N = 1337  # 実データの枚数に合わせる

# ---------------------------------------------------------------------
# 合成グラフ
# ---------------------------------------------------------------------

def build(blocks=0, shortcuts=0, band=4, seed=7):
    """帯グラフ（i と i±1..band を結ぶ＝歩きながら撮った写真の共視関係）に、
    2 種類の「空似」を混ぜる。

      shortcuts … 孤立した空似（別の場所の 1 枚と 1 枚がたまたま似ている）
      blocks    … かたまりの空似（同じ建具・同じ壁紙の 10 枚 × 10 枚。
                  互いに支え合うので厄介。SfM でいう doppelgänger）
    """
    random.seed(seed)
    edges = [(i, j) for i in range(N) for j in range(i + 1, min(N, i + band + 1))]
    for _ in range(shortcuts):
        a, b = random.randrange(N), random.randrange(N)
        if abs(a - b) > 50:
            edges.append((a, b))
    for _ in range(blocks):
        a, b = random.randrange(0, N - 20), random.randrange(0, N - 20)
        if abs(a - b) < 200:
            continue
        for x in range(10):
            for y in range(10):
                edges.append((a + x, b + y))
    adjacency = [[] for _ in range(N)]
    for a, b in edges:
        adjacency[a].append(b)
        adjacency[b].append(a)
    return adjacency


def common_neighbour_filter(adjacency, minimum=2):
    """共通近傍フィルタ。**真に隣接する 2 枚は近傍を共有する**（同じ場所の前後を
    一緒に見ている）が、別の場所の空似は共有しない。閾値を持つが、これは画素の
    見え方ではなく**グラフの構造**への閾値なので、合成グラフで挙動を固定できる。
    """
    neighbours = [set(row) for row in adjacency]
    return [[b for b in adjacency[a] if len(neighbours[a] & neighbours[b]) >= minimum]
            for a in range(N)]


# ---------------------------------------------------------------------
# 並べ替え（大域）と窓の成長（局所）
# ---------------------------------------------------------------------

def fiedler_order(adjacency, iterations=4000):
    """フィードラーベクトルによる並べ替え（冪乗法）。**大域的な最適化**。"""
    degree = [float(len(row)) for row in adjacency]
    shift = 2 * max(degree)
    vector = [((1 if i % 2 == 0 else -1) * (1 + i / N)) for i in range(N)]
    for _ in range(iterations):
        nxt = [0.0] * N
        for i in range(N):
            total = (shift - degree[i]) * vector[i]
            for j in adjacency[i]:
                total += vector[j]
            nxt[i] = total
        mean = sum(nxt) / N
        nxt = [x - mean for x in nxt]
        norm = sum(x * x for x in nxt) ** 0.5
        if norm == 0:
            break
        vector = [x / norm for x in nxt]
    return sorted(range(N), key=lambda i: vector[i])


def ball(adjacency, seed, size):
    """幅優先で size 枚集める（素朴な球）。"""
    seen, queue, out = {seed}, deque([seed]), [seed]
    while queue and len(out) < size:
        v = queue.popleft()
        for u in adjacency[v]:
            if u not in seen:
                seen.add(u)
                out.append(u)
                queue.append(u)
                if len(out) >= size:
                    break
    return out


def grow_by_support(adjacency, seed, size):
    """**支持数**（いまの集合へ何本つながっているか）が多い順に足す。

    要点: 空似の辺は 1 本しかつながらないので、本当の続き（帯グラフなら 4 本）に
    必ず負ける。**ワームホールを 1 本通っただけでは窓が飛ばない**。
    """
    inside, support = {seed}, {}
    for u in adjacency[seed]:
        support[u] = support.get(u, 0) + 1
    while len(inside) < size and support:
        best = max(support.items(), key=lambda kv: kv[1])[0]
        del support[best]
        inside.add(best)
        for u in adjacency[best]:
            if u not in inside:
                support[u] = support.get(u, 0) + 1
    return list(inside)


# ---------------------------------------------------------------------
# 評価
# ---------------------------------------------------------------------

def neighbour_agreement(order, tolerance=3):
    """真に隣り合う組が、この並びでも近いか。"""
    position = [0] * len(order)
    for rank, node in enumerate(order):
        position[node] = rank
    hit = sum(1 for i in range(N - 1) if abs(position[i] - position[i + 1]) <= tolerance)
    return hit / (N - 1)


def contamination(members, size):
    """窓の中心から窓幅ぶん以上離れた写真の割合（＝無関係な写真の混入率）。"""
    members = sorted(members)
    middle = members[len(members) // 2]
    return sum(1 for v in members if abs(v - middle) > size) / len(members)


def main():
    cases = [
        ("きれい", 0, 0),
        ("孤立した空似 20 本", 0, 20),
        ("孤立した空似 200 本", 0, 200),
        ("かたまりの空似 4 組", 4, 0),
        ("かたまり 8 組 + 孤立 200 本", 8, 200),
    ]

    print("■ 大域的な並べ替え（フィードラー）は、わずかな空似で崩れる")
    print("  条件                         隣接一致  共通近傍フィルタ後")
    for label, blocks, shortcuts in cases:
        adjacency = build(blocks, shortcuts)
        plain = neighbour_agreement(fiedler_order(adjacency))
        filtered = neighbour_agreement(fiedler_order(common_neighbour_filter(adjacency)))
        print(f"  {label:26s}   {plain:.2f}      {filtered:.2f}")

    print()
    print("■ 窓を局所的に育てると、孤立した空似には**構成上**強い")
    print("  条件                         BFS 球  支持成長  フィルタ+支持成長")
    for label, blocks, shortcuts in cases:
        adjacency = build(blocks, shortcuts)
        filtered = common_neighbour_filter(adjacency)
        seeds = range(100, N - 100, 137)

        def rate(function, graph):
            return sum(contamination(function(graph, s, 200), 200) for s in seeds) / len(seeds)

        print(f"  {label:26s}  {rate(ball, adjacency):.3f}   "
              f"{rate(grow_by_support, adjacency):.3f}    {rate(grow_by_support, filtered):.3f}")


if __name__ == "__main__":
    main()
