(local Widget {})

(macro when-let [binding & body]
  `(let ,binding
     (when ,(binding 1)
       ,body)))

(fn normalize [item]
  (match item
    {:enabled true :label label} label
    _ nil))

(fn Widget.new [name]
  {:name (or name "demo")})

(fn Widget.render [self items]
  (icollect [_ item (ipairs items)
             :let [label (normalize item)]
             :when label]
    (.. self.name ":" label)))

(fn Widget.from-file [path]
  (with-open [handle (io.open path)]
    (when-let [line (handle:read "*l")]
      (Widget.new line))))

(let [widget (Widget.new "main")]
  (print (table.concat (Widget.render widget [{:enabled true :label "alpha"}]) ", "))
  (lua "return collectgarbage('count')"))
