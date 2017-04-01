function $$ (d, s) {
  return Array.prototype.slice.apply (d.querySelectorAll (s));
} // $$

$$.root = function (n) {
  while (n.parentNode) {
    n = n.parentNode;
  }
  return n;
}; // root

function $component () { }
$component.define = function (n, c) {
  $component.handlers[n] = c;
  $$ (document, n).forEach (c);
}; // $component.define
$component.handlers = {};

$component.enableForTree = function (root) {
  (new MutationObserver (function (mutations) {
    mutations.forEach (function (m) {
      Array.prototype.forEach.call (m.addedNodes, function (x) {
        if (x.nodeType !== x.ELEMENT_NODE) return;
        Object.keys ($component.handlers).forEach (function (n) {
          if (x.localName === n) {
            $component.handlers[n] (x);
          }
          $$ (x, n).forEach ($component.handlers[n]);
        });
      });
    });
  })).observe (root, {childList: true, subtree: true});
}; // enableForTree
$component.enableForTree (document.documentElement);

$component.actions = function (e, attrName, data) {
  var p = Promise.resolve ();
  (e.getAttribute (attrName) || '').split (/\s+/).filter (function (_) {
    return _.length > 0;
  }).forEach (function (_) {
    _ = _.split (/:/);
    var actionName = _.length ? _.shift () : '';
    var arg = _.length ? _.join (':') : null;
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
      try {
        var dt = new Date (parseFloat (value) * 1000);
        f.textContent = dt.toISOString ();
      } catch (e) {
        f.textContent = value;
      }
    } else if (f.localName === 'input') {
      f.setAttribute ('data-value', value);
      f.value = value;
    } else if (f.localName === 'list-filter') {
      f.setAttribute ('value', value);
    } else if (f.localName === 'object-list') {
      f.setAttribute ('object-id', value);
    } else if (f.localName === 'if-account') {
      f.setAttribute ('account-id', value);
    } else {
      f.textContent = value;
    }
  });
  ['href', 'src', 'id'].forEach (function (name) {
    $$ (e, '[data-' + name + '-template]').forEach (function (f) {
      f.setAttribute (name, $fill.template (f.getAttribute ('data-' + name + '-template'), o));
    });
  });
} // $fill

$fill.template = function (t, o) {
  return t.replace (/\{([\w.]+)\}/g, function (_, fieldName) {
    var value = o;
    fieldName.split (/\./).forEach (function (name) {
      if (value != null) {
        value = value[name];
      } else {
        value = null;
      }
    });
    return value;
  });
}; // $fill.template

$component.define ('object-list', function (e) {
  e._main = function () {
    var type = this.getAttribute ('type');
    var q = {
      'ul': 'ul',
      'ol': 'ol',
      'table': 'table tbody',
    }[type] || 'list-main';
    return $$ (this, q)[0];
  }; // _main
  e.load = function (opts) {
    var main = this._main ();
    if (!main) return;

    if (this.hasAttribute ('object-this')) {
      var url = 'info.json';
    } else {
      var type = this.getAttribute ('object-type');
      if (this.hasAttribute ('object-selected')) {
        var url = '/' + encodeURIComponent (type) + '/selected.json';
      } else if (this.hasAttribute ('object-id')) {
        var url = '/' + encodeURIComponent (type) + '/' + encodeURIComponent (this.getAttribute ('object-id')) + '/info.json';
      } else {
        var url = '/' + encodeURIComponent (type) + '/list.json';
      }
    }
    if (opts.ref) {
      url += '?ref=' + encodeURIComponent (opts.ref);
    }
    var limit = this.getAttribute ('limit');
    if (limit) {
      url += (/\?/.test (url) ? '&' : '?') + 'limit=' + limit;
    }

    $$ (this, 'list-filter').forEach (function (f) {
      var name = f.getAttribute ('name');
      if (f.hasAttribute ('null')) {
        url += (/\?/.test (url) ? '&' : '?') + 'filter=' + encodeURIComponent (name + ':null');
      } else {
        var value = f.getAttribute ('value');
        url += (/\?/.test (url) ? '&' : '?') + 'filter=' + encodeURIComponent (name + '=' + value);
      }
    });

    if (this.hasAttribute ('reverse')) {
      opts.reverse = !opts.reverse;
      opts.prepend = !opts.prepend;
    }

    var templates = $$ (this, 'template');

    var type = this.getAttribute ('type');
    var itemType = {
      'ul': 'li',
      'ol': 'li',
      'table': 'tr',
    }[type] || 'list-item';

    return e._loading = e._loading.then (function () {
      return fetch (url, {credentials: 'same-origin'});
    }).then (function (res) {
      return res.json ();
    }).then (function (json) {
      var items = json.objects;
      var template = templates[0];
      if (!template) return;
      var added = document.createDocumentFragment ();
      items.forEach (function (item) {
        var f = document.createElement (itemType);
        var parent = f;
        if (itemType === 'list-item') {
          f.attachShadow ({"mode": "open"});
          $component.enableForTree (f.shadowRoot);
          parent = f.shadowRoot;
          $$ (document, 'link[rel~=stylesheet]').forEach (function (g) {
            parent.appendChild (g.cloneNode (true));
          });
        }
        parent.appendChild (template.content.cloneNode (true));
        $fill (parent, item);
        if (opts.reverse) {
          added.insertBefore (f, added.firstChild);
        } else {
          added.appendChild (f);
        }
        if (e._newest < item.timestamp) e._newest = item.timestamp;
      });
      if (opts.clear) main.textContent = '';
      if (added.hasChildNodes ()) {
        if (opts.prepend) {
          main.insertBefore (added, main.firstChild);
        } else {
          main.appendChild (added);
        }
        $$ (e, 'list-is-empty').forEach (function (f) { f.hidden = true });
      } else {
        $$ (e, 'list-is-empty').forEach (function (f) { f.hidden = false });
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

$component.define ('form', function (e) {
  e.onsubmit = function () {
    var body = new FormData (this);
    var controls = $$ (e, 'input:enabled, select:enabled, textarea:enabled, button:enabled');
    controls.forEach (function (c) { c.disabled = true });
    fetch (this.action, {
      method: this.method,
      body: body,
      referrerPolicy: 'origin',
      credentials: 'same-origin',
    }).then (function (res) {
      return res.json ();
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
  if (/^global:/.test (arg)) {
    arg = arg.replace (/^global:/, '');
    var list = document.getElementById (arg);
  } else {
    var list = $$.root (this).getElementById (arg);
  }
  if (!list) throw "Element #" + arg + ' not found';
  list.loadNewer ();
});

$component.defineAction ('data-submitted', 'objectListReload', function (data, arg) {
  if (/^global:/.test (arg)) {
    arg = arg.replace (/^global:/, '');
    var list = document.getElementById (arg);
  } else {
    var list = $$.root (this).getElementById (arg);
  }
  if (!list) throw "Element #" + arg + ' not found';
  list.load ({clear: true, updatePager: true});
});

$component.defineAction ('data-submitted', 'reset', function () {
  this.reset ();
});

$component.defineAction ('data-submitted', 'go', function (data, arg) {
  location.href = $fill.template (arg, data.json);
});

$component.defineAction ('data-submitted', 'reloadAccount', function (data, arg) {
  $$ (document, 'with-account, if-account').forEach (function (f) {
    f.reload ();
  });

  // XXX shadow trees
});

$component.define ('with-account', function (e) {
  e.reload = function () {
    return fetch ('/account/selected.json', {
      credentials: 'same-origin',
    }).then (function (res) {
      return res.json ();
    }).then (function (json) {
      var accountTemplate;
      var guestTemplate;
      Array.prototype.slice.call (e.children).forEach (function (f) {
        if (f.localName === 'template') {
          if (f.hasAttribute ('data-guest')) {
            guestTemplate = f;
          } else {
            accountTemplate = f;
          }
        } else {
          f.remove ();
        }
      });
      var account = json.objects[0];
      var template = account ? accountTemplate : guestTemplate;
      if (template) {
        var parent = template.content.cloneNode (true);
        $fill (parent, account);
        e.appendChild (parent);
      }
    }); // XXX error
  }; // reload
  e.reload ();
});

$component.define ('if-account', function (e) {
  e.reload = function () {
    return fetch ('/account/selected.json', {
      credentials: 'same-origin',
    }).then (function (res) {
      return res.json ();
    }).then (function (json) {
      var template;
      Array.prototype.slice.call (e.children).forEach (function (f) {
        if (f.localName === 'template') {
          template = f;
        } else {
          f.remove ();
        }
      });
      var account = json.objects[0];
      if (template && account && account.id == e.getAttribute ('account-id')) {
        var parent = template.content.cloneNode (true);
        $fill (parent, account);
        e.appendChild (parent);
      }
      e.setAttribute ('data-current-account-id', account ? account.id : null);
    }); // XXX error
  }; // reload
  e.reload ();
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
