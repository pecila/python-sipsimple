
import re
import urllib


# Classes
#

cdef class BaseCredentials:
    def __cinit__(self, *args, **kwargs):
        global _Credentials_scheme_digest, _Credentials_realm_wildcard
        self._credentials.scheme = _Credentials_scheme_digest.pj_str

    def __init__(self, str username not None, str password not None, str realm='*', bint digest=False):
        if self.__class__ is BaseCredentials:
            raise TypeError("BaseCredentials cannot be instantiated directly")
        self.username = username
        self.realm = realm
        self.password = password
        self.digest = digest

    def __repr__(self):
        return "%s(username=%r, password=%r, realm=%r, digest=%r)" % (self.__class__.__name__, self.username, self.password, self.realm, self.digest)

    def __str__(self):
        return '<%s for "%s@%s">' % (self.__class__.__name__, self.username, self.realm)

    cdef pjsip_cred_info* get_cred_info(self):
        return &self._credentials


cdef class Credentials(BaseCredentials):
    property username:
        def __get__(self):
            return self._username

        def __set__(self, str username not None):
            _str_to_pj_str(username, &self._credentials.username)
            self._username = username

    property realm:
        def __get__(self):
            return self._realm

        def __set__(self, str realm not None):
            _str_to_pj_str(realm, &self._credentials.realm)
            self._realm = realm

    property password:
        def __get__(self):
            return self._password

        def __set__(self, str password not None):
            _str_to_pj_str(password, &self._credentials.data)
            self._password = password

    property digest:
        def __get__(self):
            return self._digest

        def __set__(self, bint digest):
            self._credentials.data_type = PJSIP_CRED_DATA_DIGEST if digest else PJSIP_CRED_DATA_PLAIN_PASSWD
            self._digest = digest

    @classmethod
    def new(cls, BaseCredentials credentials):
        return cls(credentials.username, credentials.password, credentials.realm, credentials.digest)


cdef class FrozenCredentials(BaseCredentials):
    def __init__(self, str username not None, str password not None, str realm='*', bint digest=False):
        if not self.initialized:
            self.username = username
            self.realm = realm
            self.password = password
            self.digest = digest
            _str_to_pj_str(self.username, &self._credentials.username)
            _str_to_pj_str(self.realm, &self._credentials.realm)
            _str_to_pj_str(self.password, &self._credentials.data)
            self._credentials.data_type = PJSIP_CRED_DATA_DIGEST if digest else PJSIP_CRED_DATA_PLAIN_PASSWD
            self.initialized = 1
        else:
            raise TypeError("{0.__class__.__name__} is read-only".format(self))

    def __hash__(self):
        return hash((self.username, self.realm, self.password, self.digest))

    @classmethod
    def new(cls, BaseCredentials credentials):
        if isinstance(credentials, FrozenCredentials):
            return credentials
        return cls(credentials.username, credentials.password, credentials.realm, credentials.digest)


cdef class BaseSIPURI:
    def __init__(self, object host not None, object user=None, object password=None, object port=None, bint secure=False, dict parameters=None, dict headers=None):
        if self.__class__ is BaseSIPURI:
            raise TypeError("BaseSIPURI cannot be instantiated directly")
        self.host = host
        self.user = user
        self.password = password
        self.port = port
        self.secure = secure
        self.parameters = parameters if parameters is not None else {}
        self.headers = headers if headers is not None else {}

    property transport:
        def __get__(self):
            return self.parameters.get('transport', 'udp')

        def __set__(self, str transport not None):
            if transport.lower() == 'udp':
                self.parameters.pop('transport', None)
            else:
                self.parameters['transport'] = transport

    def __reduce__(self):
        return self.__class__, (self.host, self.user, self.password, self.port, self.secure, self.parameters, self.headers), None

    def __repr__(self):
        return "%s(%r, %r, %r, %r, %r, %r, %r)" % (self.__class__.__name__, self.host, self.user, self.password, self.port, self.secure, self.parameters, self.headers)

    def __str__(self):
        cdef object string = self.host
        if self.port:
            string = "%s:%d" % (string, self.port)
        if self.user is not None:
            if self.password is not None:
                string = "%s:%s@%s" % (self.user, self.password, string)
            else:
                string = "%s@%s" % (self.user, string)
        if self.parameters:
            string += ";" + ";".join(["%s%s" % (name, ("" if val is None else "="+urllib.quote(val, safe="()[]-_.!~*'/:&+$")))
                                      for name, val in self.parameters.iteritems()])
        if self.headers:
            string += "?" + "&".join(["%s%s" % (name, ("" if val is None else "="+urllib.quote(val, safe="()[]-_.!~*'/:?+$")))
                                      for name, val in self.headers.iteritems()])
        if self.secure:
            string = "sips:" + string
        else:
            string = "sip:" + string
        return string

    def __richcmp__(self, other, op):
        if not isinstance(other, BaseSIPURI):
            return NotImplemented
        if op == 2:    # 2 is ==
            return all(getattr(self, name) == getattr(other, name) for name in ("user", "password", "host", "port", "secure", "parameters", "headers"))
        elif op == 3:  # 3 is !=
            return any(getattr(self, name) != getattr(other, name) for name in ("user", "password", "host", "port", "secure", "parameters", "headers"))
        else:
            operator_map = {0: '<', 1: '<=', 2: '==', 3: '!=', 4: '>', 5: '>='}
            raise TypeError("unorderable types: {0.__class__.__name__}() {2} {1.__class__.__name__}()".format(self, other, operator_map[op]))

    def matches(self, address):
        match = re.match(r'^((?P<scheme>sip|sips):)?(?P<username>.+?)(@(?P<domain>.+?)(:(?P<port>\d+?))?)?(;(?P<parameters>.+?))?(\?(?P<headers>.+?))?$', address)
        if match is None:
            return False
        components = match.groupdict()
        if components['scheme'] is not None:
            expected_scheme = 'sips' if self.secure else 'sip'
            if components['scheme'] != expected_scheme:
                return False
        if components['username'] != self.user:
            return False
        if components['domain'] is not None and components['domain'] != self.host:
            return False
        if components['port'] is not None and int(components['port']) != self.port:
            return False
        if components['parameters']:
            parameters = dict([(name, value) for name, sep, value in [param.partition('=') for param in components['parameters'].split(';')]])
            expected_parameters = dict([(name, str(value) if value is not None else None) for name, value in self.parameters.iteritems() if name in parameters])
            if parameters != expected_parameters:
                return False
        if components['headers']:
            headers = dict([(name, value) for name, sep, value in [header.partition('=') for header in components['headers'].split('&')]])
            expected_headers = dict([(name, str(value) if value is not None else None) for name, value in self.headers.iteritems() if name in headers])
            if headers != expected_headers:
                return False
        return True


cdef class SIPURI(BaseSIPURI):
    property port:
        def __get__(self):
            return self._port

        def __set__(self, object port):
            if port is not None:
                port = int(port)
                if not (0 < port <= 65535):
                    raise ValueError("Invalid port: %d" % port)
            self._port = port

    @classmethod
    def new(cls, BaseSIPURI sipuri):
        return cls(user=sipuri.user, password=sipuri.password, host=sipuri.host, port=sipuri.port, secure=sipuri.secure, parameters=dict(sipuri.parameters), headers=dict(sipuri.headers))

    @classmethod
    def parse(cls, object uri_str):
        if not isinstance(uri_str, basestring):
            raise TypeError('a string or unicode is required')
        cdef bytes uri_bytes = str(uri_str).encode()
        cdef pjsip_uri *uri = NULL
        cdef pj_pool_t *pool = NULL
        cdef pj_str_t tmp
        cdef char buffer[4096]
        pool = pj_pool_create_on_buf("SIPURI_parse", buffer, sizeof(buffer))
        if pool == NULL:
            raise SIPCoreError("Could not allocate memory pool")
        pj_strdup2_with_null(pool, &tmp, uri_bytes)
        uri = pjsip_parse_uri(pool, tmp.ptr, tmp.slen, 0)
        if uri == NULL:
            raise SIPCoreError("Not a valid SIP URI: %s" % uri_str)
        return SIPURI_create(<pjsip_sip_uri *>pjsip_uri_get_uri(uri))


cdef class FrozenSIPURI(BaseSIPURI):
    def __init__(self, object host not None, object user=None, object password=None, object port=None, bint secure=False, frozendict parameters not None=frozendict(), frozendict headers not None=frozendict()):
        if not self.initialized:
            if port is not None:
                port = int(port)
                if not (0 < port <= 65535):
                    raise ValueError("Invalid port: %d" % port)
            self.host = host
            self.user = user
            self.password = password
            self.port = port
            self.secure = secure
            self.parameters = parameters
            self.headers = headers
            self.initialized = 1
        else:
            raise TypeError("{0.__class__.__name__} is read-only".format(self))

    property transport:
        def __get__(self):
            return self.parameters.get('transport', 'udp')

    def __hash__(self):
        return hash((self.user, self.password, self.host, self.port, self.secure, self.parameters, self.headers))

    def __richcmp__(self, other, op):  # since we define __hash__, __richcmp__ is not inherited (see https://docs.python.org/2/c-api/typeobj.html#c.PyTypeObject.tp_richcompare)
        if not isinstance(other, BaseSIPURI):
            return NotImplemented
        if op == 2:    # 2 is ==
            return all(getattr(self, name) == getattr(other, name) for name in ("user", "password", "host", "port", "secure", "parameters", "headers"))
        elif op == 3:  # 3 is !=
            return any(getattr(self, name) != getattr(other, name) for name in ("user", "password", "host", "port", "secure", "parameters", "headers"))
        else:
            operator_map = {0: '<', 1: '<=', 2: '==', 3: '!=', 4: '>', 5: '>='}
            raise TypeError("unorderable types: {0.__class__.__name__}() {2} {1.__class__.__name__}()".format(self, other, operator_map[op]))

    @classmethod
    def new(cls, BaseSIPURI sipuri):
        if isinstance(sipuri, FrozenSIPURI):
            return sipuri
        return cls(user=sipuri.user, password=sipuri.password, host=sipuri.host, port=sipuri.port, secure=sipuri.secure, parameters=frozendict(sipuri.parameters), headers=frozendict(sipuri.headers))

    @classmethod
    def parse(cls, object uri_str):
        if not isinstance(uri_str, basestring):
            raise TypeError('a string or unicode is required')
        cdef bytes uri_bytes = str(uri_str).encode()
        cdef pjsip_uri *uri = NULL
        cdef pj_pool_t *pool = NULL
        cdef pj_str_t tmp
        cdef char buffer[4096]
        pool = pj_pool_create_on_buf("FrozenSIPURI_parse", buffer, sizeof(buffer))
        if pool == NULL:
            raise SIPCoreError("Could not allocate memory pool")
        pj_strdup2_with_null(pool, &tmp, uri_bytes)
        uri = pjsip_parse_uri(pool, tmp.ptr, tmp.slen, 0)
        if uri == NULL:
            raise SIPCoreError("Not a valid SIP URI: %s" % uri_str)
        return FrozenSIPURI_create(<pjsip_sip_uri *>pjsip_uri_get_uri(uri))


# Factory functions
#

cdef dict _pj_sipuri_to_dict(pjsip_sip_uri *uri):
    cdef object scheme
    cdef pj_str_t *scheme_str
    cdef pjsip_param *param
    cdef object parameters = {}
    cdef object headers = {}
    cdef object kwargs = dict(parameters=parameters, headers=headers)
    kwargs["host"] = _pj_str_to_str(uri.host)
    scheme = _pj_str_to_str(pjsip_uri_get_scheme(<pjsip_uri *>uri)[0])
    if scheme == "sip":
        kwargs["secure"] = False
    elif scheme == "sips":
        kwargs["secure"] = True
    else:
        raise SIPCoreError("Not a sip(s) URI")
    if uri.user.slen > 0:
        kwargs["user"] = _pj_str_to_str(uri.user)
    if uri.passwd.slen > 0:
        kwargs["password"] = _pj_str_to_str(uri.passwd)
    if uri.port > 0:
        kwargs["port"] = uri.port
    if uri.user_param.slen > 0:
        parameters["user"] = _pj_str_to_str(uri.user_param)
    if uri.method_param.slen > 0:
        parameters["method"] = _pj_str_to_str(uri.method_param)
    if uri.transport_param.slen > 0:
        parameters["transport"] = _pj_str_to_str(uri.transport_param)
    if uri.ttl_param != -1:
        parameters["ttl"] = uri.ttl_param
    if uri.lr_param != 0:
        parameters["lr"] = None
    if uri.maddr_param.slen > 0:
        parameters["maddr"] = _pj_str_to_str(uri.maddr_param)
    param = <pjsip_param *> (<pj_list *> &uri.other_param).next
    while param != &uri.other_param:
        if param.value.slen == 0:
            parameters[_pj_str_to_str(param.name)] = None
        else:
            parameters[_pj_str_to_str(param.name)] = _pj_str_to_str(param.value)
        param = <pjsip_param *> (<pj_list *> param).next
    param = <pjsip_param *> (<pj_list *> &uri.header_param).next
    while param != &uri.header_param:
        if param.value.slen == 0:
            headers[_pj_str_to_str(param.name)] = None
        else:
            headers[_pj_str_to_str(param.name)] = _pj_str_to_str(param.value)
        param = <pjsip_param *> (<pj_list *> param).next
    return kwargs

cdef SIPURI SIPURI_create(pjsip_sip_uri *uri):
    cdef dict kwargs = _pj_sipuri_to_dict(uri)
    return SIPURI(**kwargs)

cdef FrozenSIPURI FrozenSIPURI_create(pjsip_sip_uri *uri):
    cdef dict kwargs = _pj_sipuri_to_dict(uri)
    kwargs["parameters"] = frozendict(kwargs["parameters"])
    kwargs["headers"] = frozendict(kwargs["headers"])
    return FrozenSIPURI(**kwargs)


# Globals
#

cdef PJSTR _Credentials_scheme_digest = PJSTR("digest")


