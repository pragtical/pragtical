(ns demo.core
  (:require [clojure.string :as str]))

(defprotocol Renderer
  (render [this items]))

(defrecord Widget [name]
  Renderer
  (render [_ items]
    (->> items
         (filter :enabled)
         (map #(str name ":" (:label %)))
         (str/join ", "))))

(defn make-widget [name]
  (->Widget (or name "demo")))
