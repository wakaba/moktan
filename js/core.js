function $$ (d, s) {
  return Array.prototype.slice.apply (d.querySelectorAll (s));
} // $$

function $component (n, c) {
  $component.handlers[n] = c;
  $$ (document, n).forEach (c);
} // $component
$component.handlers = {};

(function () {  
  (new MutationObserver (function (mutations) {
    mutations.forEach (function (m) {
      Array.prototype.forEach.call (m.addedNodes, function (x) {
        Object.keys ($component.handlers).forEach (function (n) {
          if (x.localName === n) {
            $component.handlers[n] (x);
          }
          $$ (x, n).forEach ($component.handlers[n]);
        });
      });
    });
  })).observe (document.documentElement, {childList: true, subtree: true});
}) ();

$component.actions = function (e, attrName, data) {
  var p = Promise.resolve ();
  (e.getAttribute (attrName) || '').split (/\s+/).filter (function (_) {
    return _.length > 0;
  }).forEach (function (_) {
    _ = _.split (/:/, 2);
    var actionName = _[0];
    var arg = _[1]; // or undefined
    var action = ($component.actions.handlers[attrName] || {})[actionName];
    if (!action) throw "Action |"+actionName+"| for |"+attrName+"| is not defined";
    p = p.then (function () {
      return action.call (e, data, arg);
    });
  });
  return p;
}; // actions

$component.defineAction = function (attrName, actionName, code) {
  if (!$component.actions.handlers[attrName]) $component.actions.handlers[attrName] = {};
  $component.actions.handlers[attrName][actionName] = code;
}; // defineAction
$component.actions.handlers = {};

function $fill (e, o) {
  $$ (e, '[data-field]').forEach (function (f) {
    var fieldName = f.getAttribute ('data-field');
    var value = o;
    fieldName.split (/\./).forEach (function (name) {
      if (value != null) {
        value = value[name];
      } else {
        value = null;
      }
    });
    if (f.localName === 'time') {
      var dt = new Date (parseFloat (value) * 1000);
      f.textContent = dt.toISOString ();
    } else {
      f.textContent = value;
    }
  });
  ['href'].forEach (function (name) {
    $$ (e, '[data-' + name + '-template]').forEach (function (f) {
      f.setAttribute (name, f.getAttribute ('data-' + name + '-template').replace (/\{([\w.]+)\}/g, function (_, fieldName) {
        var value = o;
        fieldName.split (/\./).forEach (function (name) {
          if (value != null) {
            value = value[name];
          } else {
            value = null;
          }
        });
        return value;
      }));
    });
  });
} // $fill

$component ('object-list', function (e) {
  e._main = function () {
    return $$ (this, 'list-main')[0];
  }; // _main
  e.load = function (opts) {
    var main = this._main ();
    if (!main) return;

    if (this.hasAttribute ('object-this')) {
      var url = 'info.json';
    } else {
      var type = this.getAttribute ('object-type');
      var url = '/' + encodeURIComponent (type) + '/list.json';
    }
    if (opts.ref) {
      url += '?ref=' + encodeURIComponent (opts.ref);
    }
    var limit = this.getAttribute ('limit');
    if (limit) {
      url += (/\?/.test (url) ? '&' : '?') + 'limit=' + limit;
    }

    var templates = $$ (this, 'template');

    return e._loading = e._loading.then (function () {
      return fetch (url, {});
    }).then (function (res) {
      return res.json ();
    }).then (function (json) {
      var items = json.objects;
      var template = templates[0];
      if (!template) return;
      var added = document.createDocumentFragment ();
      items.forEach (function (item) {
        var f = document.createElement ('list-item');
        f.appendChild (template.content.cloneNode (true));
        $fill (f, item);
        if (opts.reverse) {
          added.insertBefore (f, added.firstChild);
        } else {
          added.appendChild (f);
        }
        if (e._newest < item.timestamp) e._newest = item.timestamp;
      });
      if (opts.prepend) {
        main.insertBefore (added, main.firstChild);
      } else {
        main.appendChild (added);
      }

      if (opts.updatePager) {
        $$ (e, 'a[rel~=next]').forEach (function (f) {
          f.hidden = !json.has_next;
          f.onclick = function () {
            e.load ({updatePager: true, ref: json.next_ref});
            return false;
          };
        });
      }
    }); // XXX error
  }; // load
  e.loadNewer = function () {
    return this.load ({
      ref: Number.isFinite (this._newest) ? '+' + this._newest + ',1' : null,
      prepend: true,
      reverse: true,
    });
  }; // loadNewer
  e.clear = function () {
    var main = this._main ();
    if (!main) return;
    main.textContent = '';
    this._newest = -Infinity;
    this._loading = Promise.resolve ();
  }; // clear

  e.clear ();
  e.load ({updatePager: true});
}); // <object-list>

$component ('form', function (e) {
  e.onsubmit = function () {
    var body = new FormData (this);
    var controls = $$ (e, 'input:enabled, select:enabled, textarea:enabled, button:enabled');
    controls.forEach (function (c) { c.disabled = true });
    fetch (this.action, {
      method: this.method,
      body: body,
    }).then (function (res) {
      return res.json;
    }).then (function (json) {
      return $component.actions (e, 'data-submitted', {json: json});
    }).then (function () {
      controls.forEach (function (c) { c.disabled = false });
    }, function (error) {
      controls.forEach (function (c) { c.disabled = false });
      console.log (error); // XXX
    });
    return false;
  }; // onsubmit
}); // <form>

$component.defineAction ('data-submitted', 'objectListLoadNewer', function (data, arg) {
  var list = document.getElementById (arg);
  if (!list) throw "Element #" + arg + ' not found';
  list.loadNewer ();
});

$component.defineAction ('data-submitted', 'reset', function () {
  this.reset ();
});

/*

License:

Copyright 2017 Wakaba <wakaba@suikawiki.org>.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Affero General Public License for more details.

You does not have received a copy of the GNU Affero General Public
License along with this program, see <https://www.gnu.org/licenses/>.

*/
