import json,sys,re,html,urllib.request,os
tid=sys.argv[1]; n=int(sys.argv[2]) if len(sys.argv)>2 else 8; lim=int(sys.argv[3]) if len(sys.argv)>3 else 3000
req=urllib.request.Request(f"https://devforum.roblox.com/t/{tid}.json",headers={"Accept":"application/json","User-Agent":"Mozilla/5.0"})
d=json.load(urllib.request.urlopen(req))
print("TITLE:",d["title"],d["created_at"])
for p in d["post_stream"]["posts"][:n]:
    t=p["cooked"]; t=re.sub(r"<pre><code[^>]*>","\n```\n",t); t=t.replace("</code></pre>","\n```\n")
    t=re.sub(r"<br\s*/?>","\n",t); t=re.sub(r"</p>","\n",t); t=re.sub(r"<[^>]+>","",t); t=html.unescape(t)
    print(f"--- #{p['post_number']} {p['username']} {p['created_at'][:10]} (staff={p.get('staff')})"); print(t[:lim])
