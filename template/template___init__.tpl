# -*- coding: utf-8 -*-
from __future__ import print_function
import sys
from collections import OrderedDict
from datetime import datetime
import dateutil.parser
import inspect
import re
import logging
import pprint

import xml.etree.ElementTree as ET
import xml.dom.minidom
import json

__all__ = [
    'inf',
    'PropertyCardinalityError',
    'PropertyTypeError',
    'PropertyDefinition',
    'Property',
    'PropertyList',
    {% for t in basic_types %}
    '{{t.classname}}',
    {% endfor %}
    {% for t in processed_items if not t == 'Resource' %}
    '{{t}}',
    {% endfor %}
]

# Module global
inf = float('inf')

PRIMITIVE_TYPES = OrderedDict([
    # ('Element', 'Element'),
    ('markdown', 'str'),
    ('integer', 'int'),
    ('dateTime', 'dateTimeBase'),
    ('unsignedInt', 'int'),
    ('code', 'str'),
    ('date', 'dateTimeBase'),
    ('decimal', 'float'),
    ('uri', 'str'),
    ('id', 'str'),
    ('base64Binary', 'str'),
    ('time', 'dateTimeBase'),
    ('oid', 'str'),
    ('positiveInt', 'int'),
    ('string', 'str'),
    ('boolean', 'bool'),
    ('uuid', 'str'),
    ('instant', 'dateTimeBase'),
    ('xhtml', 'str'),
])

# ------------------------------------------------------------------------------
# Exceptions & Errors
# ------------------------------------------------------------------------------
class PropertyCardinalityError(Exception):
    def __init__(self, method, description):
        message = "Cannot {} property '{}': cardinality [{}..{}]"
        message = message.format(method, description.name, description.cmin, description.cmax)
        super(PropertyCardinalityError, self).__init__(message)
# class PropertyCardinalityError

class PropertyTypeError(Exception):
    def __init__(self, type_, description):
        msg = "Expected '{}' but got '{}' for '{}'".format(description.type, type_, description.name)
        super(PropertyTypeError, self).__init__(msg)
# class PropertyTypeError

class InvalidAttributeError(Exception):
    def __init__(self, resource_or_element, attr):
        msg = "The attribute '{}' is not a valid property for '{}'.".format(attr, resource_or_element)
        super(InvalidAttributeError, self).__init__(msg)

# ------------------------------------------------------------------------------
# Property classes to declaratively define FHIR model.
# ------------------------------------------------------------------------------
class PropertyDefinition(object):
    
    def __init__(self, name, type_, cmin, cmax, repr_='element'):
        assert name.find(' ') < 0, "'name' should not contain spaces."
        
        cmin = int(cmin)
        if cmax == '*':
            cmax = inf
        else:
            cmax = int(cmax)
        
        self.name = name
        self.type = type_
        self.cmin = cmin
        self.cmax = cmax
        self.repr = repr_
    
    def __repr__(self):
        params = {
            'name': self.name,
            'type': self.type,
            'cmin': self.cmin,
            'cmax': self.cmax,
            'repr': self.repr,
        }
        return "PropertyDefinition('{name}', '{type}', '{cmin}', '{cmax}', '{repr}')".format(**params)
# class PropertyDefinition

class PropertyMixin(object):
    def coerce_multi_type(self, value, types):
        """
            For properties that support more than one type, first check if the
            provided value actually is of one of these types. If not, we'll try
            to cast to a supported value by simply trying each supported type.
            
            Example of a property that supports more than one type:
                multi = Property(PropertyDefinition('multi', ['boolean', 'dateTime'], '0', '1'))
        """
        if isinstance(value, Element):
            if type(value).__name__ not in types:
                # FIXME: change to more meaningful exception!
                raise PropertyTypeError(type(value).__name__, self._definition)
        
            return value
        
        # Ok, so value is not (yet) a fhir type. Try to find a supported type.
        this = sys.modules[__name__]

        for type_ in self._definition.type:
            constructor = getattr(this, type_)

            try:
                value = constructor(value)
            except PropertyTypeError as e:
                # print("Apparently '{}' is not a '{}'".format(value, type_))
                pass
            else:
                return value
        
        raise Exception("Could not find a proper type for value '{}' in {}".format(value, self._definition.type))
    # def coerce_multi_type
    
    def coerce_type(self, value):
        """Coerce/cast value to correspond to PropertyDefinition."""
        logger = logging.getLogger('PropertyMixin')
        type_ = self._definition.type
        
        if value is None:
            return None
        
        # Check for multi typed properties first. isinstance will complain if
        # it recieves a list of strings as 2nd argument.
        if isinstance(type_, list):
            return self.coerce_multi_type(value, type_)
        
        # If value already has the correct type, we don't need to do anything.
        if isinstance(value, Element) and isinstance(value, type_):
            return value

        # If we're still here, try to coerce/cast. First find the constructor.
        if isinstance(type_, str):
            # PropertyDefinition.type is defined as string --> lazily evaluate.
            this = sys.modules[__name__]
            constructor = getattr(this, type_)
        else:
            # PropertyDefinition.type is already set to a constructor
            constructor = type_
        
        try:
            return constructor(value)
        except Exception as e:
            # print('!' * 80)
            # print(e)
            # print(constructor)
            # print(value)
            # print(self._definition)
            # print('!' * 80)
            raise PropertyTypeError(value.__class__.__name__, self._definition)
# class PropertyMixin
        
class Property(PropertyMixin):
    _cls_counter = 0
    
    @classmethod
    def __get_creation_counter(cls):
        cls._cls_counter += 1
        return cls._cls_counter
    
    def __init__(self, definition):
        """Create new Property instance.
        
        :param PropertyDefinition definition: Description of the property.
        """
        self._creation_order = self.__get_creation_counter()
        self._definition = definition
        self._name = definition.name
    
    def __get__(self, instance, owner):
        if instance is None:
            # instance attribute accessed on class, return self
            return self
        
        # instance attribute accessed on instance, return value
        if (self._definition.cmax > 1):
            instance._property_values.setdefault(self._name, PropertyList(self._definition))
        
        return instance._property_values.get(self._name)
    
    def __set__(self, instance, value):
        if self._definition.cmax > 1: 
            raise PropertyCardinalityError('set', self._definition)

        instance._property_values[self._name] = self.coerce_type(value)

    
    def __repr__(self):
        s = 'Property({})'.format(self._definition)
        return s
# class Property

class PropertyList(list, PropertyMixin):
    """PropertyLists are used by Propertys when cardinality > 1."""
    
    def __init__(self, definition, *args, **kwargs):
        """Create a new PropertyList instance.
        Note that minimum cardinality is not enforced when calling 'append'.
         
        :param PropertyDefinition definition: Description of the property.
        """
        super(PropertyList, self).__init__(*args, **kwargs)
        self._definition = definition

    def insert(self, i, x):
        """Insert a value into the list at position i."""
        # This raises a PropertyTypeError if x has an incorrect value.
        x = self.coerce_type(x)
        
        if len(self) >= self._definition.cmax:
            raise PropertyCardinalityError('insert', self._definition)
            
        super(PropertyList, self).insert(i, x)
         
    def append(self, x):
        """Append a value to the list."""
        # This raises a PropertyTypeError if x has an incorrect value.
        x = self.coerce_type(x)
        
        if len(self) >= self._definition.cmax:
            raise PropertyCardinalityError('append', self._definition)
            
        super(PropertyList, self).append(x)
    
    def toJSON(self):
        return []
# class PropertyList   


# ------------------------------------------------------------------------------
# Base classes
# ------------------------------------------------------------------------------
class FHIRBase(object):
    """Base class for all FHIR resources and elements."""
    _allowed_attributes = ['_property_values']

    def __init__(self, **kwargs):
        """Create a new instance."""
        self._property_values = dict()
        for attr, value in kwargs.items():
            setattr(self, attr, value)
    # def __init__
    
    def __setattr__(self, attr, value):
        if (attr not in self._allowed_attributes) and (attr not in self._getProperties()):
            raise InvalidAttributeError(type(self).__name__, attr)

        super().__setattr__(attr, value)
    # def __setattr__

    def _getProperties(self):
        """Return a list (ordered) of instance attribute names that are of type 
        'Property'
        """
        properties = []
        for attr in dir(type(self)):
            a = getattr(type(self), attr)
            if isinstance(a, Property):
                properties.append(a)
                
        properties.sort(key=lambda i: i._creation_order)
        properties = [p._definition.name for p in properties]
        
        return properties
    # def _getProperties

    @classmethod
    def marshallXML(cls, xmlstring):
        """Marshall a Resource from its XML representation."""

        def marshalRec(tag, instance, level=1):
            spaces = '  ' * level

            # The tag provides the attribute's name. Get the property(definition)
            # based on this name.
            property_name = tag.tag
            property_type = ''

            # For tags like 'valueString' the property is called 'value'. These properties
            # are *not* always simple types!
            if not hasattr(instance.__class__, property_name):
                for attr in instance._getProperties():
                    if property_name.startswith(attr):
                        property_type = property_name.replace(attr, '')
                        property_type = property_type[0].lower() + property_type[1:]
                        property_name = attr
                        break
                else:
                    raise Exception("Cannot find property '{}' on resource '{}'".format(property_name, instance.__class__.__name__))

            property_ = getattr(instance.__class__, property_name)
            desc = property_._definition

            # print('{}{} ({})'.format(spaces, property_name, property_))

            # Determine the data type of the property. Simple types all inherit from BaseType.
            # simple_type = not isinstance(desc.type, list) and issubclass(desc.type, BaseType)
            simple_type = property_type in PRIMITIVE_TYPES.keys() or issubclass(desc.type, BaseType)

            if property_type:
                this = sys.modules[__name__]
                constructor = getattr(this, property_type)

                if simple_type:
                    value = constructor(tag.get('value'))
                else:
                    value = constructor()
            elif simple_type:
                value = tag.get('value')
            else:
                # Create a new complex type instance via its constructor
                value = desc.type()

            if desc.cmax == 1:
                setattr(instance, property_name, value)
            elif desc.cmax > 1:
                getattr(instance, property_name).append(value)

            # Iterate over the tag's children: even simple types can have extensions!
            if not simple_type:
                instance = value

            for child_tag in tag:
                marshalRec(child_tag, instance, level+1)
        # def marshalRec

        self = cls()

        # Remove the default namespace definition (xmlns="http://some/namespace")
        xmlstring = re.sub('\\sxmlns="[^"]+"', '', xmlstring, count=1)
        root = ET.fromstring(xmlstring)
        if root.tag != self.__class__.__name__:
            print('*** WARNING: trying to marshall a {} in a {} ***'.format(root.tag, self.__class__.__name__))
        
        # print('')
        # print(cls.__name__)
        for tag in root:
            marshalRec(tag, self)

        return self
    # def marshallXML

    def serialize(self, format_='xml'):
        if format_ in ['xml', 'json']:
            format_ = format_.upper()
            func = getattr(self, 'to' + format_)
            return func()
    # def serialize


    def toDict(self, level=0):
        """
        {
          "resourceType": "Resource",
          "id": "...",
          "text": "...",
        }
        """
        retval = dict()
        spaces = ' ' * 2 * level

        if isinstance(self, Resource):            
            retval['resourceType'] = self.__class__.__name__

        # Iterate over *my* attributes.
        for attr in self._getProperties():
            property_def = getattr(type(self), attr)._definition
            value = getattr(self, attr)

            # Right .. a value. Let's see
            if isinstance(value, BaseType):
                if isinstance(property_def.type, list):
                    # FIXME: move to separate function/method
                    class_name = value.__class__.__name__
                    class_name = class_name[0].upper() + class_name[1:]
                    attr = attr + class_name 

                v = value.toNative()
                print('{}{}: BaseType, v: {}, type(v): {}'.format(spaces, attr, v, type(v)))
                retval[attr] = v

                json_dict = value.toDict(level)
                if json_dict:
                    retval['_' + attr] = json_dict
                
            elif isinstance(value, PropertyList):
                print('{}{}: PropertyList'.format(spaces, attr))
                listvalues = list()
                _listvalues = list()

                for v in value:
                    if isinstance(v, BaseType):
                        listvalues.append(v.toNative())
                        _v = v.toDict()
                        if not _v:
                            _v = None
                        _listvalues.append(_v)
                    else:
                        print('{}value: {}, type: {}'.format(spaces, v, type(v)))
                        listvalues.append( v.toDict(level+1) )
                
                if listvalues:
                    retval[attr] = listvalues

                if sum(map(lambda x: x is not None, _listvalues)) > 0:
                    retval['_' + attr] = _listvalues

            elif isinstance(value, Element):
                print('{}: Element'.format(attr))
                json_dict = value.toDict(level+1)

                if json_dict:
                    retval[attr] = json_dict
            elif value is not None:
                # print('attr: {}, value: {}, type: {}'.format(attr, value, type(value)))
                # return value
                pass
            
        return retval
    
    def toJSON(self):
        return json.dumps(self.toDict(), indent=4)
    
    def toXML(self, parent=None, path=None):
        """
        <parent value='value'>
          <id value='value'/>
          <extension url='url'>
            <stringValue value='value'/>
          </extension>
          <multiDateTime value="2080-01-01T00:00:00Z"/>
        </parent>
        """
        if parent is None:            
            # This will (should) only happen if I'm a Resource. Resources should
            # create the root element and iterate over their attribues.
            tag = self.__class__.__name__
            path = [tag, ]
            parent = ET.Element(tag)

            if not isinstance(self, Element):
                parent.set('xmlns', 'http://hl7.org/fhir')
        
        # Iterate over *my* attributes.
        for attr in self._getProperties():
            value = getattr(self, attr)
            desc = getattr(type(self), attr)._definition
            path_str = '.'.join(path + [attr, ])
            
            if value is not None:
                if desc.repr == 'xmlAttr':
                    parent.set(attr, str(value))
            
                elif isinstance(value, PropertyList):
                    for p in value:
                        p.toXML(ET.SubElement(parent, attr), path + [attr, ])
                        
                elif isinstance(value, FHIRBase):
                    if isinstance(desc.type, list):
                        class_name = value.__class__.__name__
                        class_name = class_name[0].upper() + class_name[1:]
                        attr = attr + class_name 
                    value.toXML(ET.SubElement(parent, attr), path + [attr, ])
                
                else:
                    print(value, type(value))
                    raise Exception('unknown property type!?')
        
        
        # Only the root element needs to generate the actual XML.
        if len(path) == 1:
            x = xml.dom.minidom.parseString(ET.tostring(parent)) 
            pretty_xml = x.toprettyxml(indent='  ')

            if isinstance(self, Element):
                pretty_xml = pretty_xml.replace('<?xml version="1.0" ?>\n', '')
                
            return pretty_xml
# class FHIRBase 
            
class Element(FHIRBase):
    """Base definition for all elements in a resource."""
    _timestamp = {{timestamp}}
    _url = 'http://hl7.org/fhir/StructureDefinition/Element'
    
    id = Property(PropertyDefinition('id', 'id', '0', '1'))
    extension = Property(PropertyDefinition('extension', 'Extension', '0', '*'))

    def __init__(self, value=None, **kwargs):
        super().__init__(**kwargs)

        if value is not None:
            self.value = value
# class Element

class Extension(Element):
    """Optional Extensions Element - found in all resources."""
    _url = 'http://hl7.org/fhir/StructureDefinition/Extension'
    
    url = Property(PropertyDefinition('url', 'uri', '1', '1', 'xmlAttr'))
    value = Property(PropertyDefinition(
        'value', 
        ['boolean', 'integer', 'decimal', 'base64Binary', 'instant', 'string', 
            'uri', 'date', 'dateTime', 'time', 'code', 'oid', 'id', 
            'unsignedInt', 'positiveInt', 'markdown', 'Annotation', 'Attachment', 
            'Identifier', 'CodeableConcept', 'Coding', 'Quantity', 'Range', 
            'Period', 'Ratio', 'SampledData', 'Signature', 'HumanName', 'Address', 
            'ContactPoint', 'Timing', 'Reference', 'Meta'], 
        '0', 
        '1')
    )

# class Extension

class BaseType(Element):
    """Base for basic/simple types."""
    
    def __repr__(self):
        """repr(x) <==> x.__repr__()"""
        return repr(self.value)

    def toNative(self):
        type_ = type(self.value)
        return type_(self.value)
# class BaseType

# ------------------------------------------------------------------------------
# date/time types
# ------------------------------------------------------------------------------

# FHIR types
# ----------
# date: {xs:date, xs:gYearMonth, xs:gYear}
#  - *no* timezone
#  - regex: -?[0-9]{4}(-(0[1-9]|1[0-2])(-(0[0-9]|[1-2][0-9]|3[0-1]))?)?

# time: 
#  - {xs:time}, *no* timezone
#  - regex: ([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]+)?
# 
# dateTime: 
#  - {xs:dateTime, xs:date, xs:gYearMonth, xs:gYear}
#  - timezone *conditional* on population of hours & minutes
#  - regex: -?[0-9]{4}(-(0[1-9]|1[0-2])(-(0[0-9]|[1-2][0-9]|3[0-1])(T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]+)?(Z|(\+|-)((0[0-9]|1[0-3]):[0-5][0-9]|14:00)))?)?)?
# 
# instant: {xs:dateTime}
#  - timezone *required*
#  - regex: <none>?
class dateTimeBase(BaseType):
    """Base class for date/time classes.
    
    The currently available modules are not capable of storing None values for
    months, days, hours, etc. As a side effect, parsing a string with only a 
    year e.g. strptime('2015', '%Y') automatically sets the month to january!?
    """
    _allowed_attributes = list(FHIRBase._allowed_attributes)
    _allowed_attributes.extend([
        '_value'
    ])

    _regex = None

    def __init__(self, value):
        super().__init__(value)

        if self._regex and re.match(self._regex, value):
            # The logic below would ideally be implemented by the subclass in
            # question, but this makes generating the subclasses much easier.
            if isinstance(self, dateTime) or isinstance(self, instant):
                p = dateutil.parser.parse(value)
                
                if isinstance(self, dateTime) and (p.hour or p.minute or p.second) and (p.tzinfo is None):
                    args = [value, self.__class__.__name__]
                    raise ValueError('"{}" is not a valid {}'.format(*args))
                
                elif isinstance(self, instant) and (p.tzinfo is None):
                    args = [value, self.__class__.__name__]
                    raise ValueError('"{}" is not a valid {}'.format(*args))
            
            self._value = value
        else:
            args = [value, self.__class__.__name__]
            raise ValueError('"{}" is not a valid {}'.format(*args))
            
    def __repr__(self):
        return repr(self._value)
    
    def __str__(self):
        return self._value
# class dateTimeBase 


# Import basic types into module/package 'fhir.model'
{% for t in basic_types %}
from ._{{t.classname.lower()}} import {{t.classname}}
{% endfor %}

# Import complex types and resources into module/package 'fhir.model'
# from fhir.resource import Resource
from .resource import Resource
{% for t in processed_items if not t == 'Resource' %}
from .{{t.lower()}} import {{t}}
{% endfor %}

# __all__ = [{% for t in types %}'{{t.classname}}', {% endfor %}]